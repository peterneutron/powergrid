package oslogger

/*
#include <os/log.h>

static inline os_log_t make_logger(const char* sub, const char* cat) {
  return os_log_create(sub, cat);
}
static inline void log_default_msg(os_log_t l, const char* msg) {
  os_log(l, "%{public}s", msg);
}

static inline void log_info_msg(os_log_t l, const char* msg) {
  os_log_info(l, "%{public}s", msg);
}

static inline void log_error_msg(os_log_t l, const char* msg) {
    os_log_error(l, "%{public}s", msg);
}
static inline void log_fault_msg(os_log_t l, const char* msg) {
    os_log_fault(l, "%{public}s", msg);
}
*/
import "C"
import (
	"fmt"
	"unsafe"
)

type Logger struct{ l C.os_log_t }

func NewLogger(subsystem, category string) *Logger {
	cs1 := C.CString(subsystem)
	defer C.free(unsafe.Pointer(cs1))
	cs2 := C.CString(category)
	defer C.free(unsafe.Pointer(cs2))
	return &Logger{C.make_logger(cs1, cs2)}
}

func (lg *Logger) Default(format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	cs := C.CString(msg)
	defer C.free(unsafe.Pointer(cs))
	C.log_default_msg(lg.l, cs)
}

func (lg *Logger) Info(format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	cs := C.CString(msg)
	defer C.free(unsafe.Pointer(cs))
	C.log_info_msg(lg.l, cs)
}

func (lg *Logger) Error(format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	cs := C.CString(msg)
	defer C.free(unsafe.Pointer(cs))
	C.log_error_msg(lg.l, cs)
}

func (lg *Logger) Fault(format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	cs := C.CString(msg)
	defer C.free(unsafe.Pointer(cs))
	C.log_fault_msg(lg.l, cs)
}
