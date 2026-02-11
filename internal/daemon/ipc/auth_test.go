package ipc

import (
	"context"
	"net"
	"testing"

	"google.golang.org/grpc/peer"
)

type testUIDAddr struct {
	uid uint32
}

func (a *testUIDAddr) Network() string { return "unix" }
func (a *testUIDAddr) String() string  { return "test" }
func (a *testUIDAddr) UID() uint32     { return a.uid }

func TestCallerUIDFromContext(t *testing.T) {
	ctx := peer.NewContext(context.Background(), &peer.Peer{Addr: &testUIDAddr{uid: 501}})
	uid, err := callerUIDFromContext(ctx)
	if err != nil {
		t.Fatalf("callerUIDFromContext returned error: %v", err)
	}
	if uid != 501 {
		t.Fatalf("unexpected uid: got=%d want=501", uid)
	}
}

func TestCallerUIDFromContextRejectsNonUIDAddr(t *testing.T) {
	ctx := peer.NewContext(context.Background(), &peer.Peer{Addr: &net.UnixAddr{Name: "/tmp/test.sock", Net: "unix"}})
	if _, err := callerUIDFromContext(ctx); err == nil {
		t.Fatal("expected error for non-UID peer address")
	}
}

func TestIsAuthorized(t *testing.T) {
	active := func() (uint32, bool) { return 502, true }

	if !isAuthorized(0, "/rpc.PowerGrid/SetChargeLimit", active) {
		t.Fatal("root caller should be authorized")
	}
	if !isAuthorized(502, "/rpc.PowerGrid/GetStatus", active) {
		t.Fatal("active user should be authorized for read")
	}
	if !isAuthorized(502, "/rpc.PowerGrid/SetPowerFeature", active) {
		t.Fatal("active user should be authorized for mutating calls")
	}
	if isAuthorized(503, "/rpc.PowerGrid/SetPowerFeature", active) {
		t.Fatal("non-active non-root caller should not be authorized")
	}
	if isAuthorized(502, "/rpc.PowerGrid/Unknown", active) {
		t.Fatal("unknown method should not be authorized")
	}
}
