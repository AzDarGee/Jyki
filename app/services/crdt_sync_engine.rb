# frozen_string_literal: true

class CrdtSyncEngine
  MUTABLE_FIELDS = {
    "Project" => %w[
      name bpm time_signature_numerator time_signature_denominator
      root_note scale_name master_volume_db swing_amount
      workspace_mode theme_name settings_jsonb
    ].freeze,
    "Track" => %w[
      name track_type deck_number position color_hex
      volume_db pan muted soloed armed fx_chain_jsonb input_routing_jsonb
    ].freeze,
    "TrackClip" => %w[
      track_id clip_kind name color_hex start_tick duration_ticks
      source_offset_ticks loop_enabled loop_start_tick loop_end_tick
      gain_db transpose_semitones detune_cents warp_enabled warp_algorithm
      time_stretch_ratio fade_in_ticks fade_out_ticks fade_curve muted
    ].freeze,
    "MidiClip" => %w[
      name length_ticks note_count events_jsonb groove_template_jsonb
    ].freeze,
    "AutomationLane" => %w[
      parameter_path min_value max_value points_jsonb bypassed
    ].freeze
  }.freeze

  FIELD_ALIASES = {
    "settings" => "settings_jsonb",
    "fx_chain" => "fx_chain_jsonb",
    "input_routing" => "input_routing_jsonb",
    "points" => "points_jsonb",
    "events" => "events_jsonb"
  }.freeze

  UUID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  class << self
    def generate_hlc(last_hlc: nil, node_id: "server", now_ms: (Time.current.to_f * 1000).to_i)
      clean_node = sanitize_node_id(node_id)
      wall_ms = now_ms.to_i
      counter = 0

      if last_hlc.present?
        parsed = parse_hlc(last_hlc)
        if parsed && wall_ms <= parsed[:wall_ms]
          wall_ms = parsed[:wall_ms]
          counter = (parsed[:counter] + 1).clamp(0, 0xffff)
        end
      end

      format("%013d-%04x-%s", wall_ms, counter, clean_node)
    end

    def parse_hlc(hlc_string)
      return nil if hlc_string.blank?

      parts = hlc_string.to_s.strip.split("-", 3)
      return nil if parts.size < 2

      {
        wall_ms: parts[0].to_i,
        counter: parts[1].to_i(16),
        node_id: (parts[2].presence || "server").to_s,
        raw: hlc_string.to_s.strip
      }
    end

    def compare_hlc(hlc_a, hlc_b)
      return 0 if hlc_a.blank? && hlc_b.blank?
      return 1 if hlc_b.blank?
      return -1 if hlc_a.blank?

      parsed_a = parse_hlc(hlc_a)
      parsed_b = parse_hlc(hlc_b)
      return hlc_a.to_s <=> hlc_b.to_s if parsed_a.nil? || parsed_b.nil?

      [ parsed_a[:wall_ms], parsed_a[:counter], parsed_a[:node_id] ] <=>
        [ parsed_b[:wall_ms], parsed_b[:counter], parsed_b[:node_id] ]
    end

    def apply_delta!(project, delta_payload)
      payload = delta_payload.to_h.with_indifferent_access
      op_id = payload[:op_id].presence || "op_#{SecureRandom.hex(4)}"
      origin_node_id = sanitize_node_id(payload[:origin_node_id].presence || "server")
      actor = payload[:actor].presence || origin_node_id
      entity_type = normalize_entity_type(payload[:entity_type])
      entity_uuid = payload[:entity_uuid].to_s.strip.presence
      entity_id = payload[:entity_id]
      action = (payload[:action].presence || "update").to_s.downcase
      incoming_hlc = payload[:hlc].presence || generate_hlc(node_id: origin_node_id)
      raw_changes = (payload[:changes] || {}).to_h.stringify_keys
      branch_name = payload[:branch_name].presence

      # Check tombstone protection before applying updates
      if entity_uuid.present? && action != "delete"
        tombstone_hlc = project.state_jsonb&.dig("tombstones", entity_uuid)
        if tombstone_hlc.present? && compare_hlc(incoming_hlc, tombstone_hlc) <= 0
          return build_response(
            ok: true,
            applied: false,
            reason: "tombstoned",
            op_id: op_id,
            origin_node_id: origin_node_id,
            actor: actor,
            entity_type: entity_type,
            entity_uuid: entity_uuid,
            action: action,
            applied_changes: {},
            rejected_fields: raw_changes.keys,
            hlc: incoming_hlc,
            state_jsonb: project.state_jsonb || {},
            serialized_entity: nil,
            project: project
          )
        end
      end

      case action
      when "create"
        apply_create_delta!(
          project: project,
          op_id: op_id,
          origin_node_id: origin_node_id,
          actor: actor,
          entity_type: entity_type,
          entity_uuid: entity_uuid,
          raw_changes: raw_changes,
          incoming_hlc: incoming_hlc,
          branch_name: branch_name
        )
      when "delete"
        apply_delete_delta!(
          project: project,
          op_id: op_id,
          origin_node_id: origin_node_id,
          actor: actor,
          entity_type: entity_type,
          entity_uuid: entity_uuid,
          entity_id: entity_id,
          incoming_hlc: incoming_hlc,
          branch_name: branch_name
        )
      else
        apply_update_delta!(
          project: project,
          op_id: op_id,
          origin_node_id: origin_node_id,
          actor: actor,
          entity_type: entity_type,
          entity_uuid: entity_uuid,
          entity_id: entity_id,
          raw_changes: raw_changes,
          incoming_hlc: incoming_hlc,
          branch_name: branch_name
        )
      end
    end

    def serialize_branch(branch)
      return nil if branch.nil?

      {
        id: branch.id,
        name: branch.name,
        delta_vector: branch.delta_vector,
        committed_at_label: branch.committed_at_label
      }
    end

    private

      def apply_update_delta!(project:, op_id:, origin_node_id:, actor:, entity_type:, entity_uuid:, entity_id:, raw_changes:, incoming_hlc:, branch_name:)
        record = locate_entity(project, entity_type, entity_uuid, entity_id)
        if record.nil?
          return build_response(
            ok: false,
            applied: false,
            reason: "not_found",
            op_id: op_id,
            origin_node_id: origin_node_id,
            actor: actor,
            entity_type: entity_type,
            entity_uuid: entity_uuid,
            action: "update",
            applied_changes: {},
            rejected_fields: raw_changes.keys,
            hlc: incoming_hlc,
            state_jsonb: {},
            serialized_entity: nil,
            project: project
          )
        end

        allowed_fields = MUTABLE_FIELDS.fetch(entity_type, [])
        applied_changes = {}
        rejected_fields = []

        record.with_lock do
          state = (record.state_jsonb || {}).deep_dup
          hlc_map = (state["hlc"] || {}).stringify_keys

          raw_changes.each do |field_key, value|
            canonical_field = FIELD_ALIASES.fetch(field_key.to_s, field_key.to_s)
            unless allowed_fields.include?(canonical_field)
              rejected_fields << field_key.to_s
              next
            end

            existing_field_hlc = hlc_map[canonical_field]
            if compare_hlc(incoming_hlc, existing_field_hlc) > 0
              coerced_value = coerce_field_value(project, entity_type, canonical_field, value)
              record.public_send("#{canonical_field}=", coerced_value)
              hlc_map[canonical_field] = incoming_hlc
              applied_changes[field_key.to_s] = record.public_send(canonical_field)
            else
              rejected_fields << field_key.to_s
            end
          end

          if applied_changes.any?
            state["hlc"] = hlc_map
            state["tombstone"] = false
            state["last_actor"] = actor
            state["last_hlc"] = incoming_hlc
            record.state_jsonb = state
            record.save!
          end
        end

        advance_project_branch!(project, incoming_hlc, actor, branch_name) if applied_changes.any?

        build_response(
          ok: true,
          applied: applied_changes.any?,
          op_id: op_id,
          origin_node_id: origin_node_id,
          actor: actor,
          entity_type: entity_type,
          entity_uuid: record.uuid,
          entity_id: record.id,
          action: "update",
          applied_changes: applied_changes,
          rejected_fields: rejected_fields,
          hlc: incoming_hlc,
          state_jsonb: record.state_jsonb || {},
          serialized_entity: serialize_entity(record, entity_type),
          project: project
        )
      end

      def apply_create_delta!(project:, op_id:, origin_node_id:, actor:, entity_type:, entity_uuid:, raw_changes:, incoming_hlc:, branch_name:)
        allowed_fields = MUTABLE_FIELDS.fetch(entity_type, [])
        record = nil
        applied_changes = {}

        project.with_lock do
          record = locate_entity(project, entity_type, entity_uuid, raw_changes["id"])
          record ||= build_new_entity(project, entity_type, entity_uuid, raw_changes)

          state = (record.state_jsonb || {}).deep_dup
          hlc_map = (state["hlc"] || {}).stringify_keys

          raw_changes.each do |field_key, value|
            canonical_field = FIELD_ALIASES.fetch(field_key.to_s, field_key.to_s)
            next unless allowed_fields.include?(canonical_field)

            coerced_value = coerce_field_value(project, entity_type, canonical_field, value)
            record.public_send("#{canonical_field}=", coerced_value)
            hlc_map[canonical_field] = incoming_hlc
            applied_changes[field_key.to_s] = record.public_send(canonical_field)
          end

          ensure_entity_defaults!(project, record, entity_type, raw_changes)

          state["hlc"] = hlc_map
          state["tombstone"] = false
          state["last_actor"] = actor
          state["last_hlc"] = incoming_hlc
          record.state_jsonb = state
          record.save!
        end

        advance_project_branch!(project, incoming_hlc, actor, branch_name)

        build_response(
          ok: true,
          applied: true,
          op_id: op_id,
          origin_node_id: origin_node_id,
          actor: actor,
          entity_type: entity_type,
          entity_uuid: record.uuid,
          entity_id: record.id,
          action: "create",
          applied_changes: applied_changes,
          rejected_fields: [],
          hlc: incoming_hlc,
          state_jsonb: record.state_jsonb || {},
          serialized_entity: serialize_entity(record, entity_type),
          project: project
        )
      end

      def apply_delete_delta!(project:, op_id:, origin_node_id:, actor:, entity_type:, entity_uuid:, entity_id:, incoming_hlc:, branch_name:)
        record = locate_entity(project, entity_type, entity_uuid, entity_id)
        target_uuid = record&.uuid || entity_uuid
        target_id = record&.id || entity_id
        deleted = false

        project.with_lock do
          state = (project.state_jsonb || {}).deep_dup
          tombstones = (state["tombstones"] || {}).stringify_keys

          if target_uuid.present?
            existing_tombstone = tombstones[target_uuid]
            if compare_hlc(incoming_hlc, existing_tombstone) > 0
              tombstones[target_uuid] = incoming_hlc
            end
          end

          state["tombstones"] = tombstones
          state["last_actor"] = actor
          state["last_hlc"] = incoming_hlc
          project.state_jsonb = state
          project.save!

          if record.present? && entity_type != "Project"
            record.destroy!
            deleted = true
          elsif target_uuid.present?
            deleted = true
          end
        end

        advance_project_branch!(project, incoming_hlc, actor, branch_name) if deleted

        build_response(
          ok: true,
          applied: deleted,
          op_id: op_id,
          origin_node_id: origin_node_id,
          actor: actor,
          entity_type: entity_type,
          entity_uuid: target_uuid,
          entity_id: target_id,
          action: "delete",
          applied_changes: { "tombstone" => true },
          rejected_fields: [],
          hlc: incoming_hlc,
          state_jsonb: project.state_jsonb || {},
          serialized_entity: { id: target_id, uuid: target_uuid, tombstone: true },
          project: project
        )
      end

      def locate_entity(project, entity_type, entity_uuid, entity_id = nil)
        case entity_type
        when "Project"
          project
        when "Track"
          find_scoped_record(project.tracks, entity_uuid, entity_id)
        when "TrackClip"
          find_scoped_record(project.track_clips, entity_uuid, entity_id)
        when "MidiClip"
          find_scoped_record(project.midi_clips, entity_uuid, entity_id)
        when "AutomationLane"
          find_scoped_record(project.automation_lanes, entity_uuid, entity_id)
        end
      end

      def find_scoped_record(scope, entity_uuid, entity_id)
        if entity_uuid.present? && entity_uuid.match?(UUID_REGEX)
          found = scope.find_by(uuid: entity_uuid)
          return found if found
        end
        return scope.find_by(id: entity_id) if entity_id.present?
        return scope.find_by(id: entity_uuid.to_i) if entity_uuid.present? && entity_uuid.match?(/\A\d+\z/)

        nil
      end

      def build_new_entity(project, entity_type, entity_uuid, raw_changes)
        record =
          case entity_type
          when "Track"
            project.tracks.build
          when "TrackClip"
            project.track_clips.build
          when "MidiClip"
            project.midi_clips.build
          when "AutomationLane"
            project.automation_lanes.build
          else
            raise ArgumentError, "Unsupported entity_type for create: #{entity_type}"
          end

        record.uuid = entity_uuid if entity_uuid.present? && entity_uuid.match?(UUID_REGEX)
        record
      end

      def ensure_entity_defaults!(project, record, entity_type, raw_changes)
        case entity_type
        when "Track"
          next_pos = (project.tracks.maximum(:position) || -1) + 1
          record.position = next_pos if raw_changes["position"].blank? && record.new_record?
          record.name = "Track #{next_pos + 1}" if record.name.blank?
          record.track_type = "audio" if record.track_type.blank?
          record.color_hex = "#38bdf8" if record.color_hex.blank?
        when "TrackClip"
          track =
            if raw_changes["track_uuid"].present?
              project.tracks.find_by(uuid: raw_changes["track_uuid"])
            elsif record.track_id.present?
              project.tracks.find_by(id: record.track_id)
            end
          track ||= project.tracks.order(:position).first
          record.track = track if track

          default_kind = track&.track_type.in?(%w[midi instrument]) ? "midi" : "audio"
          record.clip_kind = raw_changes["clip_kind"].presence || record.clip_kind.presence || default_kind

          if record.audio_sample_id.nil? && record.midi_clip_id.nil? && track
            sample, midi = StudioBootstrapper.ensure_default_clip_source_for!(track, record.clip_kind)
            record.audio_sample = sample
            record.midi_clip = midi
          end

          record.name = "#{track&.name&.split('•')&.last&.strip || 'Pattern'} Clip" if record.name.blank?
          record.color_hex = track&.color_hex || "#f59e0b" if record.color_hex.blank?
          record.duration_ticks = 3840 if record.duration_ticks.to_i <= 0
          record.loop_end_tick = record.duration_ticks if record.loop_end_tick.to_i <= 0
        end
      end

      def coerce_field_value(project, entity_type, canonical_field, value)
        if entity_type == "TrackClip" && canonical_field == "track_id" && value.is_a?(String) && value.match?(UUID_REGEX)
          target_track = project.tracks.find_by(uuid: value)
          return target_track.id if target_track
        end
        value
      end

      def advance_project_branch!(project, incoming_hlc, actor, branch_name = nil)
        branch =
          if branch_name.present?
            CrdtBranch.find_or_create_by!(name: branch_name)
          else
            project.crdt_branch || CrdtBranch.default_branches.first
          end

        return if branch.nil?

        short_hlc = incoming_hlc.to_s.split("-").first(2).join("-")
        encoded_vector = Base64.strict_encode64("hlc:#{short_hlc}:#{actor}")[0, 22]
        branch.update!(
          delta_vector: "AQt/#{encoded_vector}==",
          committed_at_label: "#{Time.current.utc.strftime('%H:%M:%S')} UTC"
        )

        if project.crdt_branch_id != branch.id
          project.update_column(:crdt_branch_id, branch.id)
          project.crdt_branch = branch
        end
      end

      def serialize_entity(record, entity_type)
        case entity_type
        when "Project"
          {
            id: record.id,
            uuid: record.uuid,
            name: record.name,
            bpm: record.bpm.to_f.round(2),
            time_signature_numerator: record.time_signature_numerator,
            time_signature_denominator: record.time_signature_denominator,
            scale_name: record.scale_name,
            master_volume_db: record.master_volume_db.to_f.round(2),
            swing_amount: record.swing_amount.to_f.round(2),
            workspace_mode: record.workspace_mode,
            theme_name: record.theme_name,
            settings: record.settings_jsonb || {},
            state_jsonb: record.state_jsonb || {}
          }
        when "Track"
          StudioBootstrapper.serialize_track(record)
        when "TrackClip"
          StudioBootstrapper.serialize_track_clip(record)
        when "AutomationLane"
          StudioBootstrapper.serialize_automation_lane(record)
        when "MidiClip"
          {
            id: record.id,
            uuid: record.uuid,
            name: record.name,
            length_ticks: record.length_ticks,
            note_count: record.note_count,
            events_jsonb: record.events_jsonb || [],
            state_jsonb: record.state_jsonb || {}
          }
        end
      end

      def build_response(attrs)
        project = attrs.delete(:project)
        applied_changes = attrs[:applied_changes] || {}
        state_jsonb = attrs[:state_jsonb] || {}
        attrs.merge(
          accepted_changes: applied_changes,
          state_hlc: state_jsonb["hlc"] || {},
          branch: serialize_branch(project&.crdt_branch)
        )
      end

      def normalize_entity_type(raw_type)
        case raw_type.to_s.strip.underscore
        when "project", "projects"
          "Project"
        when "track", "tracks"
          "Track"
        when "track_clip", "track_clips", "clip", "trackclip"
          "TrackClip"
        when "midi_clip", "midi_clips", "midiclip"
          "MidiClip"
        when "automation_lane", "automation_lanes", "automationlane"
          "AutomationLane"
        else
          "Project"
        end
      end

      def sanitize_node_id(node_id)
        node_id.to_s.gsub(/[^a-zA-Z0-9_]/, "_")[0, 32].presence || "server"
      end
  end
end
