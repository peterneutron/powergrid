package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	grpcstatus "google.golang.org/grpc/status"

	rpc "powergrid/internal/rpc"
)

const (
	socketPath  = "/var/run/powergrid.sock"
	dialTimeout = 3 * time.Second
	rpcTimeout  = 5 * time.Second
)

type commandClient struct {
	rpc rpc.PowerGridClient
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		printUsage(stdout)
		return 0
	}

	if args[0] == "help" {
		printUsage(stdout)
		return 0
	}

	conn, client, err := newCommandClient()
	if err != nil {
		fmt.Fprintln(stderr, formatCommandError(err))
		return 1
	}
	defer conn.Close()

	if err := dispatch(client, args, stdout); err != nil {
		fmt.Fprintln(stderr, formatCommandError(err))
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

	conn, err := grpc.DialContext(
		ctx,
		"passthrough:///powergrid",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(dialer),
		grpc.WithBlock(),
	)
	if err != nil {
		return nil, nil, err
	}

	return conn, &commandClient{rpc: rpc.NewPowerGridClient(conn)}, nil
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

	fmt.Fprintf(stdout, "Charge: %d%%\n", status.GetCurrentCharge())
	fmt.Fprintf(stdout, "Limit: %s\n", formatLimit(status.GetChargeLimit()))
	fmt.Fprintf(stdout, "Charging: %s\n", formatBinaryState(status.GetIsCharging()))
	fmt.Fprintf(stdout, "Connected: %s\n", formatBinaryState(status.GetIsConnected()))
	fmt.Fprintf(stdout, "Force discharge: %s\n", formatBinaryState(status.GetForceDischargeActive()))
	fmt.Fprintf(stdout, "Sleep mode: %s\n", sleepModeFromStatus(status))
	fmt.Fprintf(stdout, "Low Power Mode: %s\n", lowPowerModeState(status))
	return nil
}

func handleLimit(client *commandClient, args []string, stdout io.Writer) error {
	if len(args) == 0 || (len(args) == 1 && args[0] == "get") {
		status, err := client.getStatus()
		if err != nil {
			return err
		}
		fmt.Fprintf(stdout, "Charge limit: %s\n", formatLimit(status.GetChargeLimit()))
		return nil
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

	fmt.Fprintf(stdout, "Charge limit set to %s.\n", formatLimit(limit))
	return nil
}

func handleLowPower(client *commandClient, args []string, stdout io.Writer) error {
	action := "get"
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
	case "get":
		fmt.Fprintf(stdout, "Low Power Mode: %s\n", lowPowerModeState(status))
		return nil
	case "on", "off":
		if !status.GetLowPowerModeAvailable() {
			return fmt.Errorf("low power mode is not available on this system")
		}
		enable := action == "on"
		if err := client.setPowerFeature(rpc.PowerFeature_LOW_POWER_MODE, enable); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "Low Power Mode %s.\n", formatAppliedState(enable))
		return nil
	case "toggle":
		if !status.GetLowPowerModeAvailable() {
			return fmt.Errorf("low power mode is not available on this system")
		}
		enable := !status.GetLowPowerModeEnabled()
		if err := client.setPowerFeature(rpc.PowerFeature_LOW_POWER_MODE, enable); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "Low Power Mode %s.\n", formatAppliedState(enable))
		return nil
	default:
		return fmt.Errorf("usage: powergridctl lowpower [get|on|off|toggle]")
	}
}

func handleDischarge(client *commandClient, args []string, stdout io.Writer) error {
	action := "get"
	if len(args) > 1 {
		return fmt.Errorf("usage: powergridctl discharge [get|on|off]")
	}
	if len(args) == 1 {
		action = args[0]
	}

	switch action {
	case "get":
		status, err := client.getStatus()
		if err != nil {
			return err
		}
		fmt.Fprintf(stdout, "Force discharge: %s\n", formatBinaryState(status.GetForceDischargeActive()))
		return nil
	case "on", "off":
		enable := action == "on"
		if err := client.setPowerFeature(rpc.PowerFeature_FORCE_DISCHARGE, enable); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "Force discharge %s.\n", formatAppliedState(enable))
		return nil
	default:
		return fmt.Errorf("usage: powergridctl discharge [get|on|off]")
	}
}

func handleSleep(client *commandClient, args []string, stdout io.Writer) error {
	action := "get"
	if len(args) > 1 {
		return fmt.Errorf("usage: powergridctl sleep [get|off|system|display]")
	}
	if len(args) == 1 {
		action = args[0]
	}

	switch action {
	case "get":
		status, err := client.getStatus()
		if err != nil {
			return err
		}
		fmt.Fprintf(stdout, "Sleep mode: %s\n", sleepModeFromStatus(status))
		return nil
	case "off":
		if err := client.setPowerFeature(rpc.PowerFeature_PREVENT_DISPLAY_SLEEP, false); err != nil {
			return err
		}
		if err := client.setPowerFeature(rpc.PowerFeature_PREVENT_SYSTEM_SLEEP, false); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "Sleep mode set to off.")
		return nil
	case "system":
		if err := client.setPowerFeature(rpc.PowerFeature_PREVENT_DISPLAY_SLEEP, false); err != nil {
			return err
		}
		if err := client.setPowerFeature(rpc.PowerFeature_PREVENT_SYSTEM_SLEEP, true); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "Sleep mode set to system.")
		return nil
	case "display":
		if err := client.setPowerFeature(rpc.PowerFeature_PREVENT_SYSTEM_SLEEP, true); err != nil {
			return err
		}
		if err := client.setPowerFeature(rpc.PowerFeature_PREVENT_DISPLAY_SLEEP, true); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "Sleep mode set to display.")
		return nil
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
	if strings.EqualFold(arg, "off") {
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
		return "on"
	}
	return "off"
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
		return "display"
	case status.GetPreventSystemSleepActive():
		return "system"
	default:
		return "off"
	}
}

func lowPowerModeState(status *rpc.StatusResponse) string {
	if !status.GetLowPowerModeAvailable() {
		return "not available"
	}
	if status.GetLowPowerModeEnabled() {
		return "on"
	}
	return "off"
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

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "powergridctl: control PowerGrid through the local daemon")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Usage:")
	fmt.Fprintln(w, "  powergridctl status")
	fmt.Fprintln(w, "  powergridctl limit [60-100|off]")
	fmt.Fprintln(w, "  powergridctl lowpower [get|on|off|toggle]")
	fmt.Fprintln(w, "  powergridctl discharge [get|on|off]")
	fmt.Fprintln(w, "  powergridctl sleep [get|off|system|display]")
	fmt.Fprintln(w, "  powergridctl help")
}
