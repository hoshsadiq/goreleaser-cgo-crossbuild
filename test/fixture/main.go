package main

/*
#include <stdio.h>
#include <stdlib.h>

static void greet(const char *who) {
	printf("hello %s\n", who);
}
*/
import "C"

import "unsafe"

// The point of the fixture is the cgo import: without a C toolchain per target
// this does not build at all.
func main() {
	who := C.CString("crossbuild")
	defer C.free(unsafe.Pointer(who))
	C.greet(who)
}
