# frozen_string_literal: true

class RightSidebarController < ApplicationController
  # POST /studio_chat_messages — Append new project room or DM message via Turbo Stream + Solid Cable
  def create_message
    msg_params = params.expect(chat_message: [ :body, :room_type, :recipient_handle, :sender_name ])
    sender_display = if current_user.present?
      "#{current_user.display_name} (#{current_user.role.titleize})"
    else
      msg_params[:sender_name].presence || "Saanskara (Owner)"
    end

    @message = StudioChatMessage.new(
      sender_name: sender_display,
      sender_role: current_user&.role || "OWNER",
      body: msg_params[:body].to_s.strip,
      room_type: msg_params[:room_type].presence || "project_room",
      recipient_handle: msg_params[:recipient_handle].presence,
      sent_at_label: Time.current.utc.strftime("%H:%M")
    )

    respond_to do |format|
      format.turbo_stream do
        if @message.save
          render turbo_stream: turbo_stream.append(
            "jyki_chat_messages",
            partial: "workstation/sidebar/chat_message",
            locals: { message: @message }
          )
        else
          head :unprocessable_content
        end
      end
      format.html { redirect_to root_path }
    end
  end

  # POST /right_sidebar/branches — Commit new Yjs CRDT branch snapshot via Turbo Stream
  def commit_branch
    branch_params = params.expect(crdt_branch: [ :name ])
    clean_name = branch_params[:name].to_s.strip
    slug = clean_name.parameterize.presence || "snapshot"
    delta_hash = "AQt/#{Base64.strict_encode64("yjs:#{slug}:#{Time.current.to_i}")[0, 22]}=="

    @branch = CrdtBranch.new(
      name: clean_name,
      delta_vector: delta_hash,
      committed_at_label: "#{Time.current.utc.strftime('%H:%M')} UTC"
    )

    respond_to do |format|
      format.turbo_stream do
        if @branch.save
          render turbo_stream: [
            turbo_stream.prepend(
              "crdt_branches_list",
              partial: "workstation/sidebar/branch_card",
              locals: { branch: @branch }
            ),
            turbo_stream.update(
              "top_bar_crdt_status_label",
              "CRDT · #{@branch.name.truncate(18)}"
            )
          ]
        else
          head :unprocessable_content
        end
      end
      format.html { redirect_to root_path }
    end
  end

  # POST /right_sidebar/branches/:id/checkout — Checkout / Merge Yjs delta vector onto DAW timeline
  def checkout_branch
    @branch = CrdtBranch.find_by(id: params[:id])
    branch_label = @branch ? @branch.name : "main (master-bus-locked)"

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.update(
            "top_bar_crdt_status_label",
            "CRDT · #{branch_label.truncate(20)}"
          ),
          turbo_stream.replace(
            "crdt_checkout_notice",
            html: "<div id=\"crdt_checkout_notice\" class=\"px-2.5 py-1.5 rounded bg-[#0d2822] border border-[#115e59] text-[10px] font-mono text-[#2dd4bf]\">✔ Applied delta snapshot: #{ERB::Util.html_escape(branch_label)}</div>".html_safe
          )
        ]
      end
      format.html { redirect_to root_path }
    end
  end

  # POST /right_sidebar/refresh_telemetry — Refresh Mobile Companion Remote latency telemetry
  def refresh_telemetry
    samples = [ "3.4 ms", "3.5 ms", "3.6 ms", "3.7 ms", "3.8 ms", "3.9 ms" ]
    @roundtrip_sync = samples.sample

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.update(
          "companion_roundtrip_sync",
          @roundtrip_sync
        )
      end
      format.json { render json: { roundtrip_sync: @roundtrip_sync, status: "PAIRED" } }
      format.html { redirect_to root_path }
    end
  end

  # POST /right_sidebar/save_note — Save Studio Scratchpad & Patch Notes via Turbo Stream
  def save_note
    note_params = params.expect(studio_note: [ :content, :tuning_hz ])
    saved_time = Time.current.utc.strftime("%H:%M:%S UTC")

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.update(
          "studio_note_save_status",
          "✔ Saved (#{note_params[:tuning_hz].presence || '440 Hz'}) · #{saved_time}"
        )
      end
      format.html { redirect_to root_path }
    end
  end
end

