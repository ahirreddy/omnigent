// Waits until process <pid> shows an on-screen window taller than 200 pt and prints the time
// (unix ms), or lists its windows (id x y width height, largest first) with --list. Built by
// perf.py; needs no Accessibility permission.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

typedef struct {
  long id;
  double x, y, width, height;
} Window;

static double number(CFDictionaryRef dictionary, CFStringRef key) {
  double value = 0;
  CFNumberRef ref = CFDictionaryGetValue(dictionary, key);
  if (ref) CFNumberGetValue(ref, kCFNumberDoubleType, &value);
  return value;
}

// The process's layer-0 windows on screen; returns how many were written to `out`.
static int windows(int pid, Window *out, int capacity) {
  CFArrayRef all = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
  int count = 0;
  for (CFIndex index = 0; all && index < CFArrayGetCount(all) && count < capacity; index++) {
    CFDictionaryRef info = CFArrayGetValueAtIndex(all, index);
    if ((int)number(info, kCGWindowOwnerPID) != pid || number(info, kCGWindowLayer) != 0) continue;
    CGRect bounds = CGRectZero;
    CFDictionaryRef rect = CFDictionaryGetValue(info, kCGWindowBounds);
    if (rect) CGRectMakeWithDictionaryRepresentation(rect, &bounds);
    out[count++] = (Window){(long)number(info, kCGWindowNumber), bounds.origin.x, bounds.origin.y,
                            bounds.size.width, bounds.size.height};
  }
  if (all) CFRelease(all);
  return count;
}

static int larger_first(const void *left, const void *right) {
  double a = ((const Window *)left)->width * ((const Window *)left)->height;
  double b = ((const Window *)right)->width * ((const Window *)right)->height;
  return (a < b) - (a > b);
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: window-probe <pid> [--list]\n");
    return 2;
  }
  int pid = atoi(argv[1]);
  Window found[64];
  if (argc > 2 && strcmp(argv[2], "--list") == 0) {
    int count = windows(pid, found, 64);
    qsort(found, count, sizeof(Window), larger_first);
    for (int index = 0; index < count; index++) {
      Window window = found[index];
      printf("%ld %.0f %.0f %.0f %.0f\n", window.id, window.x, window.y, window.width,
             window.height);
    }
    return 0;
  }
  for (int attempt = 0; attempt < 12000; attempt++) {
    int count = windows(pid, found, 64);
    for (int index = 0; index < count; index++) {
      if (found[index].height > 200) {
        struct timeval now;
        gettimeofday(&now, NULL);
        printf("%.0f\n", now.tv_sec * 1000.0 + now.tv_usec / 1000.0);
        return 0;
      }
    }
    usleep(5000);
  }
  return 1;
}
