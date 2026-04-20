package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"
	grpcstatus "google.golang.org/grpc/status"

	rpc "powergrid/internal/rpc"
)

const (
	socketPath   = "/var/run/powergrid.sock"
	dialTimeout  = 3 * time.Second
	rpcTimeout   = 5 * time.Second
	actionGet    = "get"
	stateOff     = "off"
	stateOn      = "on"
	sleepSystem  = "system"
	sleepDisplay = "display"
	usageText    = "powergridctl: control PowerGrid through the local daemon\n\nUsage:\n  powergridctl status\n  powergridctl limit [60-100|off]\n  powergridctl lowpower [get|on|off|toggle]\n  powergridctl discharge [get|on|off]\n  powergridctl sleep [get|off|system|display]\n  powergridctl help\n"
)

type commandClient struct {
	rpc rpc.PowerGridClient
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		if err := printUsage(stdout); err != nil {
			_ = writeLine(stderr, err.Error())
			return 1
		}
		return 0
	}

	if args[0] == "help" {
		if err := printUsage(stdout); err != nil {
			_ = writeLine(stderr, err.Error())
			return 1
		}
		return 0
	}

	conn, client, err := newCommandClient()
	if err != nil {
		_ = writeLine(stderr, formatCommandError(err))
		return 1
	}
	defer func() {
		_ = conn.Close()
	}()

	if err := dispatch(client, args, stdout); err != nil {
		_ = writeLine(stderr, formatCommandError(err))
		return 1
	}

	return 0
}

func newCommandClient() (*grpc.ClientConn, *commandClient, error) {
	ctx, cancel := context.WithTimeout(context.Background(), dialTimeout)
	defer cancel()

	dialer := func(ctx context.Context, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socketPath)
	}

	conn, err := grpc.NewClient(
		"passthrough:///powergrid",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(dialer),
	)
	if err != nil {
		return nil, nil, err
	}
	if err := waitForReady(ctx, conn); err != nil {
		_ = conn.Close()
		return nil, nil, err
	}

	return conn, &commandClient{rpc: rpc.NewPowerGridClient(conn)}, nil
}

func waitForReady(ctx context.Context, conn *grpc.ClientConn) error {
	conn.Connect()
	for {
		state := conn.GetState()
		switch state {
		case connectivity.Ready:
			return nil
		case connectivity.Idle:
			conn.Connect()
		case connectivity.Shutdown:
			return errors.New("powergrid daemon connection shut down")
		}
		if !conn.WaitForStateChange(ctx, state) {
			return ctx.Err()
		}
	}
}

func dispatch(client *commandClient, args []string, stdout io.Writer) error {
	command := args[0]
	rest := args[1:]

	switch command {
	case "status":
		return handleStatus(client, rest, stdout)
	case "limit":
		return handleLimit(client, rest, stdout)
	case "lowpower":
		return handleLowPower(client, rest, stdout)
	case "discharge":
		return handleDischarge(client, rest, stdout)
	case "sleep":
		return handleSleep(client, rest, stdout)
	default:
		return fmt.Errorf("unknown command %q", command)
	}
}

func handleStatus(client *commandClient, args []string, stdout io.Writer) error {
	if len(args) != 0 {
		return fmt.Errorf("status does not take any arguments")
	}

	status, err := client.getStatus()
	if err != nil {
		return err
	}

	return writef(
		stdout,
		"Charge: %d%%\nLimit: %s\nCharging: %s\nConnected: %s\nForce discharge: %s\nSleep mode: %s\nLow Power Mode: %s\n",
		status.GetCurrentCharge(),
		formatLimit(status.GetChargeLimit()),
		formatBinaryState(status.GetIsCharging()),
		formatBinaryState(status.GetIsConnected()),
		formatBinaryState(status.GetForceDischargeActive()),
		sleepModeFromStatus(status),
		lowPowerModeState(status),
	)
}

func handleLimit(client *commandClient, args []string, stdout io.Writer) error {
	if len(args) == 0 || (len(args) == 1 && args[0] == actionGet) {
		status, err := client.getStatus()
		if err != nil {
			return err
		}
		return writef(stdout, "Charge limit: %s\n", formatLimit(status.GetChargeLimit()))
	}
	if len(args) != 1 {
		return fmt.Errorf("usage: powergridctl limit [60-100|off]")
	}

	limit, err := parseLimitValue(args[0])
	if err != nil {
		return err
	}
	if err := client.setLimit(limit); err != nil {
		return err
	}

	return writef(stdout, "Charge limit set to %s.\n", formatLimit(limit))
}

func handleLowPower(client *commandClient, args []string, stdout io.Writer) error {
	action := actionGet
	if len(args) > 1 {
		return fmt.Errorf("usage: powergridctl lowpower [get|on|off|toggle]")
	}
	if len(args) == 1 {
		action = args[0]
	}

	status, err := client.getStatus()
	if err != nil {
		return err
	}

	switch action {
	case actionGet:
		return writef(stdout, "Low Power Mode: %s\n", lowPowerModeState(status))
	case stateOn, stateOff:
		if !status.GetLowPowerModeAvailable() {
			return fmt.Errorf("low power mode is not available on this system")
		}
		enable := action == stateOn
		if err := client.setPowerFeature(rpc.PowerFeature_LOW_POWER_MODE, enable); err != nil {
			return err
		}
		return writef(stdout, "Low Power Mode %s.\n", formatAppliedState(enable))
	case "toggle":
		if !status.GetLowPowerModeAvailable() {
			return fmt.Errorf("low power mode is not available on this system")
		}
		enable := !status.GetLowPowerModeEnabled()
		if err := client.setPowerFeature(rpc.PowerFeature_LOW_POWER_MODE, enable); err != nil {
			return err
		}
		return writef(stdout, "Low Power Mode %s.\n", formatAppliedState(enable))
	default:
		return fmt.Errorf("usage: powergridctl lowpower [get|on|off|toggle]")
	}
}

func handleDischarge(client *commandClient, args []string, stdout io.Writer) error {
	action := actionGet
	if len(args) > 1 {
		return fmt.Errorf("usage: powergridctl discharge [get|on|off]")
	}
	if len(args) == 1 {
		action = args[0]
	}

	switch action {
	case actionGet:
		status, err := client.getStatus()
		if err != nil {
			return err
		}
		return writef(stdout, "Force discharge: %s\n", formatBinaryState(status.GetForceDischargeActive()))
	case stateOn, stateOff:
		enable := action == stateOn
		if err := client.setPowerFeature(rpc.PowerFeature_FORCE_DISCHARGE, enable); err != nil {
			return err
		}
		return writef(stdout, "Force discharge %s.\n", formatAppliedState(enable))
	default:
		return fmt.Errorf("usage: powergridctl discharge [get|on|off]")
	}
}

func handleSleep(client *commandClient, args []string, stdout io.Writer) error {
	action := actionGet
	if len(args) > 1 {
		return fmt.Errorf("usage: powergridctl sleep [get|off|system|display]")
	}
	if len(args) == 1 {
		action = args[0]
	}

	switch action {
	case actionGet:
		status, err := client.getStatus()
		if err != nil {
			return err
		}
		return writef(stdout, "Sleep mode: %s\n", sleepModeFromStatus(status))
	case stateOff:
		if err := client.setPowerFeature(rpc.PowerFeature_PREVENT_DISPLAY_SLEEP, false); err != nil {
			return err
		}
		if err := client.setPowerFeature(rpc.PowerFeature_PREVENT_SYSTEM_SLEEP, false); err != nil {
			return err
		}
		return writeLine(stdout, "Sleep mode set to off.")
	case sleepSystem:
		if err := client.setPowerFeature(rpc.PowerFeature_PREVENT_DISPLAY_SLEEP, false); err != nil {
			return err
		}
		if err := client.setPowerFeature(rpc.PowerFeature_PREVENT_SYSTEM_SLEEP, true); err != nil {
			return err
		}
		return writeLine(stdout, "Sleep mode set to system.")
	case sleepDisplay:
		if err := client.setPowerFeature(rpc.PowerFeature_PREVENT_SYSTEM_SLEEP, true); err != nil {
			return err
		}
		if err := client.setPowerFeature(rpc.PowerFeature_PREVENT_DISPLAY_SLEEP, true); err != nil {
			return err
		}
		return writeLine(stdout, "Sleep mode set to display.")
	default:
		return fmt.Errorf("usage: powergridctl sleep [get|off|system|display]")
	}
}

func (c *commandClient) getStatus() (*rpc.StatusResponse, error) {
	ctx, cancel := context.WithTimeout(context.Background(), rpcTimeout)
	defer cancel()

	return c.rpc.GetStatus(ctx, &rpc.Empty{})
}

func (c *commandClient) setLimit(limit int32) error {
	ctx, cancel := context.WithTimeout(context.Background(), rpcTimeout)
	defer cancel()

	_, err := c.rpc.ApplyMutation(ctx, &rpc.MutationRequest{
		Operation: rpc.MutationOperation_SET_CHARGE_LIMIT,
		Limit:     limit,
	})
	return err
}

func (c *commandClient) setPowerFeature(feature rpc.PowerFeature, enable bool) error {
	ctx, cancel := context.WithTimeout(context.Background(), rpcTimeout)
	defer cancel()

	_, err := c.rpc.ApplyMutation(ctx, &rpc.MutationRequest{
		Operation: rpc.MutationOperation_SET_POWER_FEATURE,
		Feature:   feature,
		Enable:    enable,
	})
	return err
}

func parseLimitValue(arg string) (int32, error) {
	if strings.EqualFold(arg, stateOff) {
		return 100, nil
	}

	limit, err := strconv.Atoi(arg)
	if err != nil {
		return 0, fmt.Errorf("invalid limit %q", arg)
	}
	if limit < 60 || limit > 100 {
		return 0, fmt.Errorf("limit must be between 60 and 100, or 'off'")
	}
	return int32(limit), nil
}

func formatLimit(limit int32) string {
	if limit >= 100 {
		return "off"
	}
	return fmt.Sprintf("%d%%", limit)
}

func formatBinaryState(enabled bool) string {
	if enabled {
		return stateOn
	}
	return stateOff
}

func formatAppliedState(enabled bool) string {
	if enabled {
		return "enabled"
	}
	return "disabled"
}

func sleepModeFromStatus(status *rpc.StatusResponse) string {
	switch {
	case status.GetPreventDisplaySleepActive():
		return sleepDisplay
	case status.GetPreventSystemSleepActive():
		return sleepSystem
	default:
		return stateOff
	}
}

func lowPowerModeState(status *rpc.StatusResponse) string {
	if !status.GetLowPowerModeAvailable() {
		return "not available"
	}
	if status.GetLowPowerModeEnabled() {
		return stateOn
	}
	return stateOff
}

func formatCommandError(err error) string {
	st, ok := grpcstatus.FromError(err)
	if !ok {
		return err.Error()
	}

	switch st.Code() {
	case codes.Unavailable:
		return "PowerGrid daemon is unavailable. Install the app or start the daemon first."
	case codes.PermissionDenied:
		return "Permission denied. Run as root or as the active console user."
	case codes.Unimplemented:
		return "The installed daemon is too old for this command. Upgrade PowerGrid."
	default:
		return st.Message()
	}
}

func printUsage(w io.Writer) error {
	_, err := io.WriteString(w, usageText)
	return err
}

func writef(w io.Writer, format string, args ...any) error {
	_, err := fmt.Fprintf(w, format, args...)
	return err
}

func writeLine(w io.Writer, text string) error {
	_, err := io.WriteString(w, text+"\n")
	return err
}
