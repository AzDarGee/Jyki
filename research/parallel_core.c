// parallel_core.c
// Compile Linux: gcc -O3 -shared -fPIC -pthread parallel_core.c -o
// libparallel.so Compile macOS: clang -O3 -dynamiclib -lpthread parallel_core.c
// -o libparallel.dylib

#include <pthread.h>
#include <stdint.h>

typedef struct {
  int thread_id;
  int num_threads;
  int total_elements;
  double *shared_buffer; // Zero-copy memory shared directly with Ruby!
} WorkerTask;

// This runs on a dedicated CPU core at bare-metal speed
void *worker_routine(void *arg) {
  WorkerTask *task = (WorkerTask *)arg;
  int start = (task->total_elements / task->num_threads) * task->thread_id;
  int end = (task->thread_id == task->num_threads - 1)
                ? task->total_elements
                : start + (task->total_elements / task->num_threads);

  for (int i = start; i < end; i++) {
    // Simulate heavy CPU work per element on shared buffer
    double val = (double)i;
    for (int k = 0; k < 500; k++) {
      val = (val * 1.000001) + 0.0001;
    }
    task->shared_buffer[i] = val;
  }
  return NULL;
}

// Called from Ruby: fans out across N CPU cores instantaneously
void parallel_process_buffer(double *buffer, int total_elements,
                             int num_cores) {
  pthread_t threads[num_cores];
  WorkerTask tasks[num_cores];

  for (int i = 0; i < num_cores; i++) {
    tasks[i].thread_id = i;
    tasks[i].num_threads = num_cores;
    tasks[i].total_elements = total_elements;
    tasks[i].shared_buffer = buffer;
    pthread_create(&threads[i], NULL, worker_routine, &tasks[i]);
  }

  for (int i = 0; i < num_cores; i++) {
    pthread_join(threads[i], NULL);
  }
}