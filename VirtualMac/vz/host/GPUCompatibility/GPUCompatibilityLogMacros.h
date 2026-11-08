#ifdef THIN_RUNTIME_LIBRARY
#include "RuntimeLog.h"
#define printf VMMThinRuntimePrint
#define fprintf VMMThinRuntimeFPrint
#endif
