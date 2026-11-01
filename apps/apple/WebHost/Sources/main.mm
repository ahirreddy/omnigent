// Omnigent Web Host: the Chromium browser process for the Omnigent Web Layer. Launched and
// supervised by OmnigentWebLayer.Session; never started by the user.
#import <Foundation/Foundation.h>

#include "OWLHost.hpp"

int main(int argc, char* argv[]) {
  @autoreleasepool {
    return owl::Host::Get().Run(argc, argv);
  }
}
