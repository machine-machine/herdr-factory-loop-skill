package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const marker = "<!-- === M2HERD:LIVE === -->"

// Overview mirrors .m2herd/overview.json (see templates/m2herd/overview.json
// and CONTRACT-m2herd.md). Unknown/absent fields default to their zero value,
// matching the shell engine's `// ""` / `// []` jq fallbacks.
type Overview struct {
	Goal          string   `json:"goal"`
	DoneWhen      string   `json:"done_when"`
	OpenQuestions []string `json:"open_questions"`
	Status        string   `json:"status"`
	UpdatedAt     string   `json:"updated_at"`
	Areas         []Area   `json:"areas"`
	Workers       []Worker `json:"workers"`
	NotesFile     string   `json:"notes_file"`
	ResumeFile    string   `json:"resume_file"`
}

type Area struct {
	Name    string   `json:"name"`
	Path    string   `json:"path"`
	Summary string   `json:"summary"`
	Related []string `json:"related"`
	Status  string   `json:"status"`
}

func (a Area) status() string {
	if a.Status == "" {
		return "active"
	}
	return a.Status
}

type Worker struct {
	Slice  string      `json:"slice"`
	State  string      `json:"state"`
	Mode   string      `json:"mode"`
	Model  string      `json:"model"`
	Tokens json.Number `json:"tokens"`
	Branch string      `json:"branch"`
	PaneID string      `json:"pane_id"`
}

// LoadOverview reads and parses <dir>/.m2herd/overview.json.
func LoadOverview(dir string) (*Overview, error) {
	b, err := os.ReadFile(filepath.Join(dir, ".m2herd", "overview.json"))
	if err != nil {
		return nil, err
	}
	var ov Overview
	if err := json.Unmarshal(b, &ov); err != nil {
		return nil, fmt.Errorf("overview.json: %w", err)
	}
	if ov.Status == "" {
		ov.Status = "active"
	}
	return &ov, nil
}

// HasFabric reports whether dir looks like an m2herd fabric root.
func HasFabric(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, ".m2herd", "overview.json"))
	return err == nil
}

// Drift compares overview.json areas[] against the context/ tree, same logic
// as `m2herd.sh sync --check`: dirs with no matching area are "missing",
// listed areas with no matching dir are "orphan". clean == no drift.
// A ReadDir failure is returned as err with clean=true: an unreadable tree is
// a warning, not evidence that every listed area is orphan.
func Drift(dir string, ov *Overview) (clean bool, missing, orphan []string, err error) {
	tree := map[string]bool{}
	entries, err := os.ReadDir(filepath.Join(dir, ".m2herd", "context"))
	if err != nil {
		return true, nil, nil, err
	}
	for _, e := range entries {
		if e.IsDir() {
			tree[e.Name()] = true
		}
	}
	listed := map[string]bool{}
	for _, a := range ov.Areas {
		listed[a.Name] = true
	}
	for n := range tree {
		if !listed[n] {
			missing = append(missing, n)
		}
	}
	for n := range listed {
		if !tree[n] {
			orphan = append(orphan, n)
		}
	}
	sort.Strings(missing)
	sort.Strings(orphan)
	return len(missing) == 0 && len(orphan) == 0, missing, orphan, nil
}

var hdrFieldRe = regexp.MustCompile(`(?m)^([a-zA-Z_]+):\s*(.*)$`)

// headerField reads a `key: value` line from a context.md annotation header
// (the "---\n...\n---\n" block written by write_header in scripts/m2herd.sh),
// stripping a trailing "  # comment".
func headerField(path, key string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(string(b), "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		return ""
	}
	for _, line := range lines[1:] {
		if strings.TrimSpace(line) == "---" {
			break
		}
		m := hdrFieldRe.FindStringSubmatch(line)
		if m != nil && m[1] == key {
			v := m[2]
			if i := strings.Index(v, "#"); i >= 0 {
				v = v[:i]
			}
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// AreaAge returns the humanized age (42s/3m/7h/4d) of an area's context.md
// `updated:` header field, or "?" when missing/unparseable.
func AreaAge(dir, area string) string {
	v := headerField(filepath.Join(dir, ".m2herd", "context", area, "context.md"), "updated")
	if v == "" {
		return "?"
	}
	t, err := time.Parse(time.RFC3339, v)
	if err != nil {
		return "?"
	}
	return ageString(time.Since(t))
}

func ageString(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	s := int(d.Seconds())
	switch {
	case s < 60:
		return fmt.Sprintf("%ds", s)
	case s < 3600:
		return fmt.Sprintf("%dm", s/60)
	case s < 86400:
		return fmt.Sprintf("%dh", s/3600)
	default:
		return fmt.Sprintf("%dd", s/86400)
	}
}

// NoteLine is one parsed line from the NOTES.md live tail.
type NoteLine struct {
	Raw  string
	When time.Time
	Text string
	HasT bool
}

var noteLineRe = regexp.MustCompile(`^- \[([^\]]+)\]\s?(.*)$`)

// NotesTail returns up to n non-blank lines below the marker in NOTES.md.
func NotesTail(dir string, n int) []NoteLine {
	b, err := os.ReadFile(filepath.Join(dir, ".m2herd", "NOTES.md"))
	if err != nil {
		return nil
	}
	content := string(b)
	idx := strings.Index(content, marker)
	if idx < 0 {
		return nil
	}
	live := content[idx+len(marker):]
	var nonBlank []string
	for _, line := range strings.Split(live, "\n") {
		if strings.TrimSpace(line) != "" {
			nonBlank = append(nonBlank, line)
		}
	}
	if len(nonBlank) > n {
		nonBlank = nonBlank[len(nonBlank)-n:]
	}
	out := make([]NoteLine, 0, len(nonBlank))
	for _, line := range nonBlank {
		nl := NoteLine{Raw: line, Text: line}
		if m := noteLineRe.FindStringSubmatch(line); m != nil {
			if t, err := time.Parse(time.RFC3339, m[1]); err == nil {
				nl.When, nl.HasT = t, true
				nl.Text = m[2]
			}
		}
		out = append(out, nl)
	}
	return out
}

// HumanNoteTime renders an ISO8601Z note timestamp local-short: "15:04" if
// today, "Jan 2 15:04" otherwise.
func HumanNoteTime(t time.Time) string {
	local := t.Local()
	if local.Format("2006-01-02") == time.Now().Format("2006-01-02") {
		return local.Format("15:04")
	}
	return local.Format("Jan 2 15:04")
}

// BudgetInfo is the preferred /tmp/claude-ctx-*.json context-bridge reading.
type BudgetInfo struct {
	Present bool
	Pct     int
	Budget  int64
	Age     string
	Session string // session id from the bridge filename, "" when unknown
}

// bridgeSessionID extracts the session id ctx-bridge.sh embeds in its
// filename (/tmp/claude-ctx-<session-id>.json).
func bridgeSessionID(path string) string {
	base := filepath.Base(path)
	base = strings.TrimPrefix(base, "claude-ctx-")
	return strings.TrimSuffix(base, ".json")
}

// liveClaudeSessions returns session ids of Claude Code sessions whose
// transcript (~/.claude/projects/<slug>/<session-id>.jsonl) was written in
// the last 5 minutes — best available "session is live" signal. Best-effort:
// nil when the directory is absent or unreadable.
func liveClaudeSessions() map[string]bool {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	matches, _ := filepath.Glob(filepath.Join(home, ".claude", "projects", "*", "*.jsonl"))
	live := map[string]bool{}
	for _, m := range matches {
		fi, err := os.Stat(m)
		if err != nil || time.Since(fi.ModTime()) > 5*time.Minute {
			continue
		}
		live[strings.TrimSuffix(filepath.Base(m), ".jsonl")] = true
	}
	return live
}

// LoadBudget scans /tmp/claude-ctx-*.json for the first file with a numeric
// .used_pct, mirroring budget_row() in scripts/m2herd.sh. Files older than
// 30 min are ignored, files owned by the current uid are preferred, then
// files whose session id matches a live claude session, then newest first —
// so with several fresh bridge files the one backed by a session that is
// actually running wins.
func LoadBudget() BudgetInfo {
	matches, _ := filepath.Glob("/tmp/claude-ctx-*.json")
	uid := os.Getuid()
	live := liveClaudeSessions()
	type candidate struct {
		path string
		mod  time.Time
		mine bool
		live bool
	}
	var cands []candidate
	for _, m := range matches {
		fi, err := os.Stat(m)
		if err != nil || time.Since(fi.ModTime()) > 30*time.Minute {
			continue
		}
		mine := false
		if st, ok := fi.Sys().(*syscall.Stat_t); ok {
			mine = int(st.Uid) == uid
		}
		cands = append(cands, candidate{path: m, mod: fi.ModTime(), mine: mine, live: live[bridgeSessionID(m)]})
	}
	sort.Slice(cands, func(i, j int) bool {
		if cands[i].mine != cands[j].mine {
			return cands[i].mine
		}
		if cands[i].live != cands[j].live {
			return cands[i].live
		}
		return cands[i].mod.After(cands[j].mod)
	})
	for _, c := range cands {
		m := c.path
		b, err := os.ReadFile(m)
		if err != nil {
			continue
		}
		var raw map[string]json.RawMessage
		if err := json.Unmarshal(b, &raw); err != nil {
			continue
		}
		usedRaw, ok := raw["used_pct"]
		if !ok {
			continue
		}
		var pctF float64
		if err := json.Unmarshal(usedRaw, &pctF); err != nil {
			continue
		}
		budget := int64(384000)
		if br, ok := raw["budget"]; ok {
			var bf float64
			if err := json.Unmarshal(br, &bf); err == nil {
				budget = int64(bf)
			}
		}
		if budget <= 0 {
			continue
		}
		return BudgetInfo{Present: true, Pct: int(pctF), Budget: budget, Age: ageString(time.Since(c.mod)), Session: bridgeSessionID(m)}
	}
	return BudgetInfo{}
}

// SliceResumes reads resume counts from the current run's slice traces
// (.m2herd/runs/<CURRENT>/slices/*/status.json). Best-effort and read-only:
// any missing file, empty CURRENT, or unparseable trace is skipped silently.
// Only slices with resumes>0 appear in the map; nil when none.
func SliceResumes(dir string) map[string]int {
	cur, err := os.ReadFile(filepath.Join(dir, ".m2herd", "runs", "CURRENT"))
	if err != nil {
		return nil
	}
	run := strings.TrimSpace(string(cur))
	if run == "" {
		return nil
	}
	matches, _ := filepath.Glob(filepath.Join(dir, ".m2herd", "runs", run, "slices", "*", "status.json"))
	out := map[string]int{}
	for _, m := range matches {
		b, err := os.ReadFile(m)
		if err != nil {
			continue
		}
		var st struct {
			Slice   string `json:"slice"`
			Resumes int    `json:"resumes"`
		}
		if json.Unmarshal(b, &st) != nil || st.Resumes <= 0 {
			continue
		}
		slice := st.Slice
		if slice == "" {
			slice = filepath.Base(filepath.Dir(m))
		}
		out[slice] = st.Resumes
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// UpdateBanner is the cached ~/.cache/m2herd/update-status reading.
type UpdateBanner struct {
	Behind int
	Show   bool
}

// LoadUpdateBanner shows the banner only when the cache says "behind" and the
// check is fresher than 24h, mirroring update_row() in scripts/m2herd.sh.
func LoadUpdateBanner() UpdateBanner {
	home, err := os.UserHomeDir()
	if err != nil {
		return UpdateBanner{}
	}
	b, err := os.ReadFile(filepath.Join(home, ".cache", "m2herd", "update-status"))
	if err != nil {
		return UpdateBanner{}
	}
	fields := strings.Fields(strings.TrimSpace(string(b)))
	if len(fields) < 3 || fields[0] != "behind" {
		return UpdateBanner{}
	}
	n, err := strconv.Atoi(fields[1])
	if err != nil {
		return UpdateBanner{}
	}
	t, err := time.Parse(time.RFC3339, fields[2])
	if err != nil {
		return UpdateBanner{}
	}
	// A future-dated check is clock skew or a corrupt cache — treat as stale,
	// otherwise the banner would pin until the timestamp is finally passed.
	if d := time.Since(t); d < 0 || d >= 24*time.Hour {
		return UpdateBanner{}
	}
	return UpdateBanner{Behind: n, Show: true}
}

// NextLine execs `m2herd next --dir <dir>` with a 3s timeout, mirroring the
// dashboard's NEXT row. ok is false when the binary is missing, errors, or
// times out — callers render a graceful skip in that case.
func NextLine(dir string) (line string, ok bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "m2herd", "next", "--dir", dir)
	// Without WaitDelay a grandchild inheriting stdout keeps the pipe open and
	// blocks Output() past the context deadline, leaking a goroutine per tick.
	cmd.WaitDelay = 2 * time.Second
	out, err := cmd.Output()
	if err != nil {
		return "", false
	}
	return strings.TrimSpace(string(out)), true
}

// HerdrAgents queries `herdr agent list` once for pane_id -> agent_status,
// mirroring render_workers() in scripts/m2herd.sh. ok is false (skip
// silently) when herdr is absent, errors, or times out.
func HerdrAgents() (statusByPane map[string]string, ok bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "herdr", "agent", "list")
	cmd.WaitDelay = 2 * time.Second
	out, err := cmd.Output()
	if err != nil {
		return nil, false
	}
	var payload struct {
		Result struct {
			Agents []struct {
				PaneID      string `json:"pane_id"`
				AgentStatus string `json:"agent_status"`
			} `json:"agents"`
		} `json:"result"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return nil, false
	}
	statusByPane = make(map[string]string, len(payload.Result.Agents))
	for _, a := range payload.Result.Agents {
		statusByPane[a.PaneID] = a.AgentStatus
	}
	return statusByPane, true
}

// ReadResume reads .m2herd/RESUME.md for the 'r' modal.
func ReadResume(dir string) (string, error) {
	b, err := os.ReadFile(filepath.Join(dir, ".m2herd", "RESUME.md"))
	if err != nil {
		return "", err
	}
	return string(b), nil
}
