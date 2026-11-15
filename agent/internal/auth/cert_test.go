package auth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func TestLoadOrCreateCertGeneratesP256ForTenYears(t *testing.T) {
	now := time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)
	cert, err := LoadOrCreateCert(filepath.Join(t.TempDir(), "tls"), "vps", now)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		t.Fatalf("parse certificate: %v", err)
	}
	key, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || key.Curve != elliptic.P256() {
		t.Fatalf("public key = %T, want ECDSA P-256", leaf.PublicKey)
	}
	if years := leaf.NotAfter.Sub(now).Hours() / 24 / 365; years < 9.9 || years > 10.1 {
		t.Errorf("validity = %.2f years, want 10", years)
	}
	if leaf.NotBefore.After(now) {
		t.Errorf("NotBefore %s is after creation time %s", leaf.NotBefore, now)
	}
}

func TestLoadOrCreateCertIsStableAcrossRestarts(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "tls")
	first, err := LoadOrCreateCert(dir, "vps", time.Now())
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	second, err := LoadOrCreateCert(dir, "vps", time.Now().Add(24*time.Hour))
	if err != nil {
		t.Fatalf("reload certificate: %v", err)
	}
	fp1, err := Fingerprint(first)
	if err != nil {
		t.Fatalf("fingerprint: %v", err)
	}
	fp2, err := Fingerprint(second)
	if err != nil {
		t.Fatalf("fingerprint: %v", err)
	}
	if fp1 != fp2 {
		t.Errorf("fingerprint changed across restarts: %s != %s", fp1, fp2)
	}
}

func TestPrivateKeyIsOwnerOnly(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix permissions")
	}
	dir := filepath.Join(t.TempDir(), "tls")
	if _, err := LoadOrCreateCert(dir, "vps", time.Now()); err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	info, err := os.Stat(filepath.Join(dir, keyFile))
	if err != nil {
		t.Fatalf("stat key: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("key permissions = %o, want 600", perm)
	}
}

func TestLoadOrCreateCertFailsOnCorruptFiles(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{certFile, keyFile} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("garbage"), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	if _, err := LoadOrCreateCert(dir, "vps", time.Now()); err == nil {
		t.Fatal("corrupt certificate was accepted or silently replaced")
	}
}

func TestFingerprintIsBase64URLSHA256OfSPKI(t *testing.T) {
	cert, err := LoadOrCreateCert(filepath.Join(t.TempDir(), "tls"), "vps", time.Now())
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	got, err := Fingerprint(cert)
	if err != nil {
		t.Fatalf("fingerprint: %v", err)
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		t.Fatalf("parse certificate: %v", err)
	}
	spki, err := x509.MarshalPKIXPublicKey(leaf.PublicKey)
	if err != nil {
		t.Fatalf("marshal spki: %v", err)
	}
	sum := sha256.Sum256(spki)
	if want := base64.RawURLEncoding.EncodeToString(sum[:]); got != want {
		t.Errorf("fingerprint = %s, want %s", got, want)
	}
}
