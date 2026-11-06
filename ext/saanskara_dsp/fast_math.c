// ext/saanskara_dsp/fast_math.c
#include <stdint.h>

#define EXPORT __attribute__((visibility("default")))

EXPORT double apply_golden_ratio(double value, uint32_t iterations) {
    const double phi = 1.618033988749895;
    for (uint32_t i = 0; i < iterations; i++) {
        double prod = value * phi;
        value = prod - (long)prod;
    }
    return value;
}