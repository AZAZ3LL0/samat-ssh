package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"text/tabwriter"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
)

func runTokens(ctx context.Context, e env, args []string, out io.Writer) error {
	switch {
	case len(args) == 1 && args[0] == "list":
		return listTokens(ctx, e, out)
	case len(args) == 2 && args[0] == "revoke":
		return revokeToken(ctx, e, args[1], out)
	default:
		return usageError("tokens: want `list` or `revoke <id>`")
	}
}

func listTokens(ctx context.Context, e env, out io.Writer) error {
	tokens, err := e.auth.Tokens(ctx)
	if err != nil {
		return err
	}
	table := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	_, _ = fmt.Fprintln(table, "ID\tDEVICE\tCREATED\tLAST USED\tSTATUS")
	for _, token := range tokens {
		status := "active"
		if token.RevokedAt != nil {
			status = "revoked"
		}
		_, _ = fmt.Fprintf(table, "%s\t%s\t%s\t%s\t%s\n",
			token.ID, token.DeviceName, token.CreatedAt.Format(timeFormat), formatOptional(token.LastUsedAt), status)
	}
	return table.Flush()
}

func revokeToken(ctx context.Context, e env, id string, out io.Writer) error {
	err := e.auth.Revoke(ctx, id)
	if errors.Is(err, auth.ErrTokenNotFound) {
		return fmt.Errorf("no active token with id %q", id)
	}
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(out, "revoked %s\n", id)
	return err
}

func formatOptional(t *time.Time) string {
	if t == nil {
		return "never"
	}
	return t.Format(timeFormat)
}
