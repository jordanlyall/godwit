// Package mobile is the gomobile-bound surface of Godwit for iOS (and later
// Android). It owns the core.Service for the app's lifetime and speaks the
// Local API (ADR 0002) to the shell: Call goes through rpc.Client against the
// owner's own socket, so roles, audit and redaction apply unchanged.
//
// SKETCH — written against the signatures read from the repo on 2026-11-08
// (core.New/core.Options in core/service.go, rpcbind.Listen in rpcbind/bind.go,
// rpc.Dial and Client.Call in rpc/, Service.Subscribe in core/service.go).
// It has not been compiled. Fix it against the tree before binding.
//
// gomobile bind restrictions: exported functions may use basic types, string,
// []byte, error, and Go interfaces whose methods use those. Everything richer
// is JSON — which is what the Local API is anyway.
package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"sync"

	"github.com/godwit-email/godwit/core"
	"github.com/godwit-email/godwit/rpc"
	"github.com/godwit-email/godwit/rpcbind"
)

// Host is what the shell provides to the core. Swift implements it.
// The Secret* methods back core.Options.Keyring (seam patch 0001): the real
// shell wraps SecItem; the spike's Host may use an in-memory dictionary.
// SecretGet returns ("", nil) for a missing entry: gomobile allows one value
// plus an error, and can't carry a sentinel error across the bridge; no
// credential Godwit stores is the empty string.
type Host interface {
	SecretGet(service, account string) (string, error)
	SecretSet(service, account, value string) error
	SecretDelete(service, account string) error
	// Log receives one line of core/mobile logging for the Xcode console.
	Log(line string)
}

// hostKeyring adapts Host to core.Keyring, mapping an empty value to
// core.ErrSecretNotFound so a missing credential reads as reauth_required
// rather than an unavailable keychain.
type hostKeyring struct{ h Host }

func (k hostKeyring) Get(service, user string) (string, error) {
	v, err := k.h.SecretGet(service, user)
	if err != nil {
		return "", err
	}
	if v == "" {
		return "", core.ErrSecretNotFound
	}
	return v, nil
}

func (k hostKeyring) Set(service, user, secret string) error {
	return k.h.SecretSet(service, user, secret)
}

func (k hostKeyring) Delete(service, user string) error {
	return k.h.SecretDelete(service, user)
}

// EventSink receives core/events.Event as JSON. Swift implements it.
type EventSink interface {
	OnEvent(eventJSON string)
}

var (
	mu     sync.Mutex
	svc    *core.Service
	srv    *rpc.Server
	client *rpc.Client
	cancel context.CancelFunc
	host   Host
)

// Start opens dataDir, starts the Local API on its socket and dials it with
// the full role. dataDir must be short: sun_path is 104 bytes and an iOS
// container path is already ~100, so pass the app's Documents directory
// itself, not a subdirectory. systemLanguage is BCP 47 ("" = "en").
func Start(dataDir, systemLanguage, appVersion string, h Host) error {
	mu.Lock()
	defer mu.Unlock()
	if svc != nil {
		return nil
	}
	host = h

	// The mygo sqlite plugin dlopens the library named here (purego). iOS ships
	// libsqlite3 in the dyld shared cache; apps link it all the time. Verify
	// FTS5 during the spike (PRAGMA compile_options). Fallback: an embedded
	// framework built from mygo/plugins/sqlite/native/sqlite.c.
	if os.Getenv("MYGO_SQLITE_LIBRARY") == "" {
		_ = os.Setenv("MYGO_SQLITE_LIBRARY", "/usr/lib/libsqlite3.dylib")
	}

	ctx, c := context.WithCancel(context.Background())
	s, err := core.New(ctx, core.Options{
		DataDir:        dataDir,
		AutoSync:       true,
		LabelMail:      false, // spike: no background classifiers
		SecurityMail:   false,
		SystemLanguage: systemLanguage,
		AppVersion:     appVersion,
		Registry:       nil, // plugin directory off on iOS v1
		// internal/sysproxy's darwin path uses CFNetworkCopySystemProxySettings,
		// which exists on iOS; keep nil to try it, or return nil here to bypass.
		SystemProxy: func(*url.URL) *url.URL { return nil },
		// Keyring: the shell's keychain (seam patch 0001). nil would mean
		// go-keyring, which shells out to /usr/bin/security and cannot work here.
		Keyring: hostKeyring{h},
		// SystemTranslator / AppleIntelligence: nil leaves those built-in
		// plugins out. Later they are Swift implementations handed in via Host.
	})
	if err != nil {
		c()
		return err
	}

	server, err := rpcbind.Listen(dataDir, s, appVersion)
	if err != nil {
		c()
		_ = s.Close()
		return err
	}
	go func() {
		if err := server.Serve(ctx); err != nil && h != nil {
			h.Log("local api: " + err.Error())
		}
	}()

	cl, err := rpc.Dial(dataDir, "full", "ios", rpcbind.NewCodec())
	if err != nil {
		c()
		_ = server.Close()
		_ = s.Close()
		return err
	}

	svc, srv, client, cancel = s, server, cl, c
	return nil
}

// Call invokes a Local API method. paramsJSON is a JSON array of positional
// params ("" or "[]" for none); the result is the method's result as JSON.
// Streaming methods (channel results) are not supported here yet — add
// Stream(method, paramsJSON, sink) when the shell needs one.
func Call(method, paramsJSON string) (string, error) {
	mu.Lock()
	cl := client
	mu.Unlock()
	if cl == nil {
		return "", errors.New("mobile: not started")
	}
	var args []any
	if paramsJSON != "" {
		if err := json.Unmarshal([]byte(paramsJSON), &args); err != nil {
			return "", err
		}
	}
	var res json.RawMessage
	if err := cl.Call(context.Background(), method, &res, args...); err != nil {
		return "", err
	}
	if res == nil {
		return "null", nil
	}
	return string(res), nil
}

// Subscribe forwards core events to sink as JSON until Stop. Call once.
func Subscribe(sink EventSink) error {
	mu.Lock()
	s := svc
	mu.Unlock()
	if s == nil {
		return errors.New("mobile: not started")
	}
	ch, unsub := s.Subscribe()
	go func() {
		defer unsub()
		for e := range ch {
			b, err := json.Marshal(e)
			if err != nil {
				continue
			}
			sink.OnEvent(string(b))
		}
	}()
	return nil
}

// Stop closes the client, the Local API and the core. Safe to call twice.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()
	if svc == nil {
		return nil
	}
	var first error
	if client != nil {
		if err := client.Close(); err != nil && first == nil {
			first = err
		}
	}
	cancel()
	if srv != nil {
		if err := srv.Close(); err != nil && first == nil {
			first = err
		}
	}
	if err := svc.Close(); err != nil && first == nil {
		first = err
	}
	svc, srv, client, cancel = nil, nil, nil, nil
	return first
}
