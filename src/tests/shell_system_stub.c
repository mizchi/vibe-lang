#include <stdint.h>
#include <stdlib.h>

int32_t vibe_shell_system(uint8_t *cmd) {
  return (int32_t)system((const char *)cmd);
}
