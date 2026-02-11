package ipc

import (
	"context"
	"fmt"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

type ActiveUIDProvider func() (uint32, bool)

const AuthMode = "root-or-active-console-user"

func AuthUnaryInterceptor(activeUID ActiveUIDProvider) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		uid, err := callerUIDFromContext(ctx)
		if err != nil {
			return nil, status.Error(codes.PermissionDenied, err.Error())
		}

		if !isAuthorized(uid, info.FullMethod, activeUID) {
			return nil, status.Errorf(codes.PermissionDenied, "unauthorized caller uid=%d for method=%s", uid, info.FullMethod)
		}

		return handler(ctx, req)
	}
}

func callerUIDFromContext(ctx context.Context) (uint32, error) {
	p, ok := peer.FromContext(ctx)
	if !ok || p.Addr == nil {
		return 0, fmt.Errorf("missing peer information")
	}

	addr, ok := p.Addr.(UIDAddr)
	if !ok {
		return 0, fmt.Errorf("peer credentials unavailable")
	}

	return addr.UID(), nil
}

func isAuthorized(uid uint32, fullMethod string, activeUID ActiveUIDProvider) bool {
	if uid == 0 {
		return true
	}

	current, ok := activeUID()
	if !ok {
		return false
	}

	switch fullMethod {
	case "/rpc.PowerGrid/GetStatus", "/rpc.PowerGrid/GetVersion", "/rpc.PowerGrid/GetDaemonInfo", "/rpc.PowerGrid/ApplyMutation":
		return uid == current
	default:
		return false
	}
}
