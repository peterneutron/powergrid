package consoleuser

import (
	"os"
	"os/user"
	"syscall"
)

type ConsoleUser struct {
	Username string
	UID      uint32
	HomeDir  string
}

func Current() (*ConsoleUser, error) {
	fi, err := os.Stat("/dev/console")
	if err != nil {
		return nil, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return nil, nil
	}
	if st.Uid == 0 {
		return nil, nil
	}
	u, err := user.LookupId(intToString(int(st.Uid)))
	if err != nil {
		return &ConsoleUser{UID: st.Uid}, nil
	}
	return &ConsoleUser{Username: u.Username, UID: st.Uid, HomeDir: u.HomeDir}, nil
}

func intToString(i int) string {
	if i == 0 {
		return "0"
	}
	neg := false
	if i < 0 {
		neg = true
		i = -i
	}
	var b [20]byte
	bp := len(b)
	for i > 0 {
		bp--
		b[bp] = byte('0' + i%10)
		i /= 10
	}
	if neg {
		bp--
		b[bp] = '-'
	}
	return string(b[bp:])
}
