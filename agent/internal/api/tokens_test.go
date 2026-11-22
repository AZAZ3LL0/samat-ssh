package api_test

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
)

// Device management (S1.4, S1.6): list the paired devices, revoke another one, unpair this one.
// Every response here goes through the contract validator.

func (f *fixture) deleteWithKey(path, token, key string) *httptest.ResponseRecorder {
	f.t.Helper()
	request := httptest.NewRequest(http.MethodDelete, path, nil)
	request.Header.Set("Authorization", "Bearer "+token)
	if key != "" {
		request.Header.Set("Idempotency-Key", key)
	}
	request.RemoteAddr = phone
	recorder := httptest.NewRecorder()
	f.checked.ServeHTTP(recorder, request)
	return recorder
}

func (f *fixture) tokens(path, token string) gen.DeviceTokenPage {
	f.t.Helper()
	response := f.get(path, token)
	if response.Code != http.StatusOK {
		f.t.Fatalf("GET %s status = %d, body %s", path, response.Code, response.Body)
	}
	var page gen.DeviceTokenPage
	decode(f.t, response, &page)
	return page
}

func ids(page gen.DeviceTokenPage) []string {
	result := make([]string, 0, len(page.Items))
	for _, item := range page.Items {
		result = append(result, item.Id)
	}
	return result
}

func TestListTokensShowsActiveDevicesAndMarksTheCaller(t *testing.T) {
	f := newFixture(t)
	phoneToken, phoneID := f.token()
	f.now = f.now.Add(time.Minute)
	_, tabletID := f.token()
	f.now = f.now.Add(time.Minute)
	_, revokedID := f.token()
	if err := f.auth.Revoke(t.Context(), revokedID); err != nil {
		t.Fatalf("revoke: %v", err)
	}

	page := f.tokens("/v1/tokens", phoneToken)
	if got := ids(page); len(got) != 2 || got[0] != phoneID || got[1] != tabletID {
		t.Fatalf("ids = %v, want [%s %s] oldest first without the revoked one", got, phoneID, tabletID)
	}
	if !page.Items[0].Current || page.Items[1].Current {
		t.Errorf("current = %v, %v; want only the caller's token", page.Items[0].Current, page.Items[1].Current)
	}
	if page.Items[0].DeviceName != "iPhone" || !page.Items[0].CreatedAt.Equal(f.now.Add(-2*time.Minute)) {
		t.Errorf("first item = %+v", page.Items[0])
	}
	if !page.NextCursor.IsNull() {
		t.Errorf("nextCursor = %v, want null on the last page", page.NextCursor)
	}
}

func TestListTokensPagesWithCursor(t *testing.T) {
	f := newFixture(t)
	token, first := f.token()
	want := []string{first}
	for range 4 {
		f.now = f.now.Add(time.Second)
		_, id := f.token()
		want = append(want, id)
	}

	var got []string
	path := "/v1/tokens?limit=2"
	for pages := 0; ; pages++ {
		if pages > 3 {
			t.Fatal("cursor does not end")
		}
		page := f.tokens(path, token)
		if len(page.Items) > 2 {
			t.Fatalf("page of %d items, limit 2", len(page.Items))
		}
		got = append(got, ids(page)...)
		if page.NextCursor.IsNull() {
			break
		}
		cursor, err := page.NextCursor.Get()
		if err != nil {
			t.Fatalf("nextCursor: %v", err)
		}
		path = "/v1/tokens?limit=2&cursor=" + cursor
	}
	if len(got) != len(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("ids = %v, want %v", got, want)
		}
	}
}

func TestListTokensRejectsBadPaging(t *testing.T) {
	f := newFixture(t)
	token, _ := f.token()
	for _, path := range []string{"/v1/tokens?limit=0", "/v1/tokens?limit=1001", "/v1/tokens?cursor=not-a-cursor"} {
		wantError(t, f.get(path, token), http.StatusBadRequest, gen.InvalidRequest)
	}
}

func TestTokenEndpointsRequireAToken(t *testing.T) {
	f := newFixture(t)
	wantError(t, f.get("/v1/tokens", ""), http.StatusUnauthorized, gen.Unauthorized)
	wantError(t, f.deleteWithKey("/v1/tokens/self", "", uuid.NewString()), http.StatusUnauthorized, gen.Unauthorized)
}

func TestRevokeTokenLocksOutTheOtherDevice(t *testing.T) {
	f := newFixture(t)
	phoneToken, _ := f.token()
	tabletToken, tabletID := f.token()

	if response := f.deleteWithKey("/v1/tokens/"+tabletID, phoneToken, uuid.NewString()); response.Code != http.StatusNoContent {
		t.Fatalf("status = %d, body %s", response.Code, response.Body)
	}
	wantError(t, f.get("/v1/tokens", tabletToken), http.StatusUnauthorized, gen.Unauthorized)
	if got := ids(f.tokens("/v1/tokens", phoneToken)); len(got) != 1 {
		t.Errorf("ids = %v, want only the phone", got)
	}
	// A second revoke with a new key finds the token already revoked: still done.
	if response := f.deleteWithKey("/v1/tokens/"+tabletID, phoneToken, uuid.NewString()); response.Code != http.StatusNoContent {
		t.Errorf("repeat status = %d, body %s", response.Code, response.Body)
	}
}

func TestRevokeTokenErrors(t *testing.T) {
	f := newFixture(t)
	token, _ := f.token()
	wantError(t, f.deleteWithKey("/v1/tokens/unknown", token, uuid.NewString()), http.StatusNotFound, gen.NotFound)
	wantError(t, f.deleteWithKey("/v1/tokens/unknown", token, ""), http.StatusBadRequest, gen.InvalidRequest)
	wantError(t, f.deleteWithKey("/v1/tokens/unknown", token, "not-a-uuid"), http.StatusBadRequest, gen.InvalidRequest)
}

func TestRevokeTokenIsIdempotentPerKey(t *testing.T) {
	f := newFixture(t)
	phoneToken, _ := f.token()
	_, tabletID := f.token()
	_, laptopID := f.token()
	key := uuid.NewString()

	first := f.deleteWithKey("/v1/tokens/"+tabletID, phoneToken, key)
	second := f.deleteWithKey("/v1/tokens/"+tabletID, phoneToken, key)
	if first.Code != http.StatusNoContent || second.Code != first.Code || second.Body.String() != first.Body.String() {
		t.Fatalf("responses = %d %q, %d %q; want the same 204 twice", first.Code, first.Body, second.Code, second.Body)
	}
	// The same key on another device is another request.
	wantError(t, f.deleteWithKey("/v1/tokens/"+laptopID, phoneToken, key), http.StatusConflict, gen.IdempotencyConflict)
	if got := ids(f.tokens("/v1/tokens", phoneToken)); len(got) != 2 {
		t.Errorf("ids = %v, want the phone and the laptop", got)
	}
}

func TestRevokeOwnTokenUnpairsTheCaller(t *testing.T) {
	f := newFixture(t)
	phoneToken, _ := f.token()
	tabletToken, _ := f.token()
	key := uuid.NewString()

	if response := f.deleteWithKey("/v1/tokens/self", phoneToken, key); response.Code != http.StatusNoContent {
		t.Fatalf("status = %d, body %s", response.Code, response.Body)
	}
	wantError(t, f.get("/v1/tokens", phoneToken), http.StatusUnauthorized, gen.Unauthorized)
	// The contract tells the client to read a 401 on retry as done.
	wantError(t, f.deleteWithKey("/v1/tokens/self", phoneToken, key), http.StatusUnauthorized, gen.Unauthorized)
	if got := ids(f.tokens("/v1/tokens", tabletToken)); len(got) != 1 {
		t.Errorf("ids = %v, want only the tablet", got)
	}
	wantError(t, f.deleteWithKey("/v1/tokens/self", tabletToken, ""), http.StatusBadRequest, gen.InvalidRequest)
}
