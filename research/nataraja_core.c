// nataraja_core.c
// Zero dependencies. Pure C + POSIX threads + Hardware Atomics.

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>

// This exact 32-byte memory layout is shared directly with Ruby via Fiddle!
typedef struct {
  volatile int32_t completed_chunks; // Updated atomically by C cores
  int32_t total_chunks;              // Read by Ruby to calculate % (0..100)
  volatile int32_t status; // 0 = Idle, 1 = Running, 2 = Done, 3 = Cancelled
  int32_t num_cores;       // Number of CPU cores unleashed
  double *buffer;          // Pointer to shared zero-copy data array
  double checksum;         // Final result computed across all cores
} JobState;

typedef struct {
  int core_id;
  JobState *job;
} CoreWorkerArg;

static void *tandava_worker(void *raw_arg) {
  CoreWorkerArg *arg = (CoreWorkerArg *)raw_arg;
  JobState *job = arg->job;
  int id = arg->core_id;
  int n = job->num_cores;
  int tot = job->total_chunks;
  free(arg); // Clean up our tiny heap arg immediately

  double local_sum = 0.0;

  // Stride across chunks so all cores work evenly
  for (int chunk = id; chunk < tot; chunk += n) {
    // Check if Ruby user clicked "Cancel" (status == 3)
    if (__atomic_load_n(&job->status, __ATOMIC_ACQUIRE) == 3) {
      return NULL;
    }

    // Heavy bare-metal CPU work per chunk
    double val = (double)(chunk + 1);
    for (int iter = 0; iter < 400000; iter++) {
      val = (val * 1.00000001) + 0.000001;
    }
    job->buffer[chunk] = val;
    local_sum += val;

    // Hardware atomic increment (Lock-free! Zero mutexes!)
    int32_t done =
        __atomic_add_fetch(&job->completed_chunks, 1, __ATOMIC_SEQ_CST);

    // The very last chunk to finish marks the whole job as Done (2)
    if (done == tot) {
      __atomic_store_n(&job->status, 2, __ATOMIC_RELEASE);
    }
  }

  // Atomically fold our core's sum into the final checksum
  // (Using a simple CAS loop for double precision)
  double old_val, new_val;
  do {
    old_val = job->checksum;
    new_val = old_val + local_sum;
  } while (!__sync_bool_compare_and_swap((uint64_t *)&job->checksum,
                                         *(uint64_t *)&old_val,
                                         *(uint64_t *)&new_val));

  return NULL;
}

// Non-blocking launch! Spawns threads and returns to Ruby in < 0.1ms.
// The GVL is NEVER held during the heavy computation!
void launch_parallel_job(JobState *job) {
  __atomic_store_n(&job->completed_chunks, 0, __ATOMIC_SEQ_CST);
  __atomic_store_n(&job->status, 1, __ATOMIC_SEQ_CST); // 1 = Running
  job->checksum = 0.0;

  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);

  for (int i = 0; i < job->num_cores; i++) {
    CoreWorkerArg *arg = (CoreWorkerArg *)malloc(sizeof(CoreWorkerArg));
    arg->core_id = i;
    arg->job = job;

    pthread_t tid;
    pthread_create(&tid, &attr, tandava_worker, arg);
  }

  pthread_attr_destroy(&attr);
}

// Instant atomic abort signal from Ruby UI
void cancel_parallel_job(JobState *job) {
  __atomic_store_n(&job->status, 3, __ATOMIC_SEQ_CST);
}