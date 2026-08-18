// A shim header so the module map does not need pkg-config: the header is
// found through the platform include path on Linux and through the SDK on
// Apple platforms.
#include <zlib.h>
