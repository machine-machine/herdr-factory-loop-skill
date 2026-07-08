package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const settingsToastDuration = 1500 * time.Millisecond

var (
	agentCycle  = []string{"claude", "codex", "cursor", "opencode"}
	runnerCycle = []string{"pane", "headless"}
)

// SettingsDefaults duplicates the engine defaults from scripts/m2herd.sh
// settings_get, the shell sibling that non-TUI callers use.
type SettingsDefaults struct {
	Orchestrator SettingsEndpoint `json:"orchestrator"`
	Workers      SettingsEndpoint `json:"workers"`
	Routing      []RoutingRule    `json:"routing"`
}

type SettingsEndpoint struct {
	Agent  string `json:"agent,omitempty"`
	Runner string `json:"runner,omitempty"`
}

type RoutingRule struct {
	Pattern string `json:"pattern"`
	Agent   string `json:"agent"`
	Runner  string `json:"runner,omitempty"`
	Model   string `json:"model,omitempty"`
}

type Settings struct {
	Orchestrator SettingsEndpoint `json:"orchestrator,omitempty"`
	Workers      SettingsEndpoint `json:"workers,omitempty"`
	Routing      []RoutingRule    `json:"routing,omitempty"`
}

var settingsDefaults = SettingsDefaults{
	Orchestrator: SettingsEndpoint{Agent: "claude", Runner: "pane"},
	Workers:      SettingsEndpoint{Agent: "claude", Runner: "pane"},
	Routing:      []RoutingRule{},
}

type settingsMsg struct {
	settings Settings
	err      error
}

type settingsSavedMsg struct {
	settings Settings
	err      error
}

type settingsToastMsg time.Time

type settingsView struct {
	loading bool
	err     error

	settings Settings
	cursor   int

	inputMode   settingsInputMode
	inputPrompt string
	inputValue  string
	inputRow    settingsRow

	confirmDelete bool
	deleteRule    int

	toast     string
	toastRed  bool
	toastLive bool
}

type settingsInputMode int

const (
	settingsInputNone settingsInputMode = iota
	settingsInputString
	settingsInputAddRule
)

type settingsRowKind int

const (
	settingsRowField settingsRowKind = iota
	settingsRowRulePattern
	settingsRowRuleAgent
	settingsRowRuleRunner
	settingsRowRuleModel
)

// settingsRows layout: settingsFieldRows fixed endpoint rows, then
// settingsRowsPerRule rows (pattern/agent/runner/model) per routing rule.
const (
	settingsFieldRows   = 4
	settingsRowsPerRule = 4
)

type settingsRow struct {
	Kind    settingsRowKind
	Section string
	Field   string
	Rule    int
}

func loadSettingsCmd(dir string) tea.Cmd {
	return func() tea.Msg {
		s, err := LoadSettings(dir)
		return settingsMsg{settings: s, err: err}
	}
}

func saveSettingsCmd(dir string, s Settings) tea.Cmd {
	return func() tea.Msg {
		err := SaveSettings(dir, s)
		return settingsSavedMsg{settings: s, err: err}
	}
}

func settingsToastCmd() tea.Cmd {
	return tea.Tick(settingsToastDuration, func(t time.Time) tea.Msg { return settingsToastMsg(t) })
}

func settingsPath(dir string) string {
	return filepath.Join(dir, ".m2herd", "settings.json")
}

func LoadSettings(dir string) (Settings, error) {
	path := settingsPath(dir)
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Settings{}, nil
	}
	if err != nil {
		return Settings{}, err
	}
	var s Settings
	if err := json.Unmarshal(b, &s); err != nil {
		return Settings{}, fmt.Errorf("settings.json: %w", err)
	}
	normalizeSettings(&s)
	return s, nil
}

func SaveSettings(dir string, s Settings) error {
	normalizeSettings(&s)
	if err := validateSettings(s); err != nil {
		return err
	}
	path := settingsPath(dir)
	lockPath := path + ".lock"
	lock, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)

	payload, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	payload = append(payload, '\n')
	tmp, err := os.CreateTemp(filepath.Dir(path), ".settings.json.*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	ok := false
	defer func() {
		if !ok {
			_ = os.Remove(tmpName)
		}
	}()
	if _, err := tmp.Write(payload); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	ok = true
	return nil
}

func normalizeSettings(s *Settings) {
	for i := range s.Routing {
		s.Routing[i].Pattern = strings.TrimSpace(s.Routing[i].Pattern)
	}
}

func validateSettings(s Settings) error {
	checkAgent := func(label, v string) error {
		if v == "" || inList(v, agentCycle) {
			return nil
		}
		return fmt.Errorf("%s agent must be one of %s", label, strings.Join(agentCycle, ", "))
	}
	checkRunner := func(label, v string) error {
		if v == "" || inList(v, runnerCycle) {
			return nil
		}
		return fmt.Errorf("%s runner must be one of %s", label, strings.Join(runnerCycle, ", "))
	}
	if err := checkAgent("orchestrator", s.Orchestrator.Agent); err != nil {
		return err
	}
	if err := checkRunner("orchestrator", s.Orchestrator.Runner); err != nil {
		return err
	}
	if err := checkAgent("workers", s.Workers.Agent); err != nil {
		return err
	}
	if err := checkRunner("workers", s.Workers.Runner); err != nil {
		return err
	}
	for i, r := range s.Routing {
		if strings.TrimSpace(r.Pattern) == "" {
			return fmt.Errorf("routing rule %d pattern is empty", i+1)
		}
		if err := checkAgent(fmt.Sprintf("routing rule %d", i+1), r.Agent); err != nil {
			return err
		}
		if err := checkRunner(fmt.Sprintf("routing rule %d", i+1), r.Runner); err != nil {
			return err
		}
	}
	return nil
}

func resolvedEndpoint(ep SettingsEndpoint, def SettingsEndpoint) SettingsEndpoint {
	if ep.Agent == "" {
		ep.Agent = def.Agent
	}
	if ep.Runner == "" {
		ep.Runner = def.Runner
	}
	return ep
}

func settingsRows(s Settings) []settingsRow {
	rows := []settingsRow{
		{Kind: settingsRowField, Section: "orchestrator", Field: "agent"},
		{Kind: settingsRowField, Section: "orchestrator", Field: "runner"},
		{Kind: settingsRowField, Section: "workers", Field: "agent"},
		{Kind: settingsRowField, Section: "workers", Field: "runner"},
	}
	for i := range s.Routing {
		rows = append(rows,
			settingsRow{Kind: settingsRowRulePattern, Section: "routing", Field: "pattern", Rule: i},
			settingsRow{Kind: settingsRowRuleAgent, Section: "routing", Field: "agent", Rule: i},
			settingsRow{Kind: settingsRowRuleRunner, Section: "routing", Field: "runner", Rule: i},
			settingsRow{Kind: settingsRowRuleModel, Section: "routing", Field: "model", Rule: i},
		)
	}
	return rows
}

func (m model) updateSettingsKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	sv := m.settings
	if msg.String() == "ctrl+c" {
		return m, tea.Quit
	}
	if sv.inputMode != settingsInputNone {
		return m.updateSettingsInput(msg)
	}
	if sv.confirmDelete {
		switch msg.String() {
		case "y", "Y":
			if sv.deleteRule >= 0 && sv.deleteRule < len(sv.settings.Routing) {
				sv.settings.Routing = append(sv.settings.Routing[:sv.deleteRule], sv.settings.Routing[sv.deleteRule+1:]...)
				sv.confirmDelete = false
				sv.clampCursor()
				return m, saveSettingsCmd(m.dir, sv.settings)
			}
			sv.confirmDelete = false
			return m, nil
		case "n", "N", "esc":
			sv.confirmDelete = false
			return m, nil
		}
		return m, nil
	}
	switch msg.String() {
	case "esc":
		m.settings = nil
		return m, nil
	case "j", "down":
		sv.cursor++
		sv.clampCursor()
		return m, nil
	case "k", "up":
		sv.cursor--
		sv.clampCursor()
		return m, nil
	case "enter", " ":
		row, ok := sv.currentRow()
		if !ok {
			return m, nil
		}
		switch row.Kind {
		case settingsRowField, settingsRowRuleAgent, settingsRowRuleRunner:
			sv.cycleRow(row)
			return m, saveSettingsCmd(m.dir, sv.settings)
		case settingsRowRulePattern:
			sv.inputMode = settingsInputString
			sv.inputPrompt = "pattern"
			sv.inputValue = sv.settings.Routing[row.Rule].Pattern
			sv.inputRow = row
			return m, nil
		case settingsRowRuleModel:
			sv.inputMode = settingsInputString
			sv.inputPrompt = "model (empty = default)"
			sv.inputValue = sv.settings.Routing[row.Rule].Model
			sv.inputRow = row
			return m, nil
		}
	case "?":
		m.showHelp = true
		return m, nil
	case "a":
		sv.inputMode = settingsInputAddRule
		sv.inputPrompt = "new pattern"
		sv.inputValue = ""
		return m, nil
	case "d":
		row, ok := sv.currentRow()
		if ok && row.Kind != settingsRowField {
			sv.confirmDelete = true
			sv.deleteRule = row.Rule
		}
		return m, nil
	case "r":
		row, ok := sv.currentRow()
		if !ok {
			return m, nil
		}
		if sv.resetRow(row) {
			sv.setToast("reset to default", false)
			return m, tea.Batch(saveSettingsCmd(m.dir, sv.settings), settingsToastCmd())
		}
		sv.setToast("no default for pattern", true)
		return m, settingsToastCmd()
	}
	return m, nil
}

func (m model) updateSettingsInput(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	sv := m.settings
	switch msg.String() {
	case "esc":
		sv.inputMode = settingsInputNone
		sv.inputValue = ""
		return m, nil
	case "enter":
		v := strings.TrimSpace(sv.inputValue)
		switch sv.inputMode {
		case settingsInputAddRule:
			// Invalid input keeps the minibuffer open (typed text intact) with
			// a red toast; only esc discards.
			if v == "" {
				sv.setToast("invalid: routing pattern is empty", true)
				return m, settingsToastCmd()
			}
			sv.settings.Routing = append(sv.settings.Routing, RoutingRule{Pattern: v, Agent: settingsDefaults.Workers.Agent})
			normalizeSettings(&sv.settings)
			sv.cursor = settingsFieldRows + (findRule(sv.settings.Routing, v) * settingsRowsPerRule) + 1
			sv.inputMode = settingsInputNone
			sv.clampCursor()
			return m, saveSettingsCmd(m.dir, sv.settings)
		case settingsInputString:
			row := sv.inputRow
			if row.Rule >= 0 && row.Rule < len(sv.settings.Routing) {
				switch row.Kind {
				case settingsRowRulePattern:
					if v == "" {
						sv.setToast("invalid: pattern is empty (d deletes the rule)", true)
						return m, settingsToastCmd()
					}
					sv.settings.Routing[row.Rule].Pattern = v
				case settingsRowRuleModel:
					sv.settings.Routing[row.Rule].Model = v // empty clears → workers default
				default:
					sv.inputMode = settingsInputNone
					return m, nil
				}
				normalizeSettings(&sv.settings)
				sv.inputMode = settingsInputNone
				sv.clampCursor()
				return m, saveSettingsCmd(m.dir, sv.settings)
			}
		}
		sv.inputMode = settingsInputNone
		return m, nil
	case "backspace", "ctrl+h":
		if len(sv.inputValue) > 0 {
			r := []rune(sv.inputValue)
			sv.inputValue = string(r[:len(r)-1])
		}
		return m, nil
	}
	if len(msg.Runes) > 0 {
		sv.inputValue += string(msg.Runes)
	}
	return m, nil
}

func (sv *settingsView) currentRow() (settingsRow, bool) {
	rows := settingsRows(sv.settings)
	if len(rows) == 0 {
		return settingsRow{}, false
	}
	sv.clampCursor()
	return rows[sv.cursor], true
}

func (sv *settingsView) clampCursor() {
	rows := settingsRows(sv.settings)
	if len(rows) == 0 {
		sv.cursor = 0
		return
	}
	if sv.cursor < 0 {
		sv.cursor = len(rows) - 1
	}
	if sv.cursor >= len(rows) {
		sv.cursor = 0
	}
}

func (sv *settingsView) cycleRow(row settingsRow) {
	switch row.Kind {
	case settingsRowField:
		switch row.Section + "." + row.Field {
		case "orchestrator.agent":
			sv.settings.Orchestrator.Agent = cycleValue(sv.settings.Orchestrator.Agent, agentCycle)
		case "orchestrator.runner":
			sv.settings.Orchestrator.Runner = cycleValue(sv.settings.Orchestrator.Runner, runnerCycle)
		case "workers.agent":
			sv.settings.Workers.Agent = cycleValue(sv.settings.Workers.Agent, agentCycle)
		case "workers.runner":
			sv.settings.Workers.Runner = cycleValue(sv.settings.Workers.Runner, runnerCycle)
		}
	case settingsRowRuleAgent:
		if row.Rule >= 0 && row.Rule < len(sv.settings.Routing) {
			sv.settings.Routing[row.Rule].Agent = cycleValue(sv.settings.Routing[row.Rule].Agent, agentCycle)
		}
	case settingsRowRuleRunner:
		if row.Rule >= 0 && row.Rule < len(sv.settings.Routing) {
			sv.settings.Routing[row.Rule].Runner = cycleValue(sv.settings.Routing[row.Rule].Runner, runnerCycle)
		}
	}
}

func (sv *settingsView) resetRow(row settingsRow) bool {
	switch row.Kind {
	case settingsRowField:
		switch row.Section + "." + row.Field {
		case "orchestrator.agent":
			sv.settings.Orchestrator.Agent = ""
		case "orchestrator.runner":
			sv.settings.Orchestrator.Runner = ""
		case "workers.agent":
			sv.settings.Workers.Agent = ""
		case "workers.runner":
			sv.settings.Workers.Runner = ""
		}
		return true
	case settingsRowRuleAgent:
		if row.Rule >= 0 && row.Rule < len(sv.settings.Routing) {
			sv.settings.Routing[row.Rule].Agent = ""
			return true
		}
	case settingsRowRuleRunner:
		if row.Rule >= 0 && row.Rule < len(sv.settings.Routing) {
			sv.settings.Routing[row.Rule].Runner = ""
			return true
		}
	case settingsRowRuleModel:
		if row.Rule >= 0 && row.Rule < len(sv.settings.Routing) {
			sv.settings.Routing[row.Rule].Model = ""
			return true
		}
	}
	return false
}

func (sv *settingsView) setToast(text string, red bool) {
	sv.toast = text
	sv.toastRed = red
	sv.toastLive = true
}

func findRule(rules []RoutingRule, pattern string) int {
	for i, r := range rules {
		if r.Pattern == pattern {
			return i
		}
	}
	return len(rules) - 1
}

func RenderSettings(sv *settingsView, width int) string {
	if width < minWidth {
		width = minWidth
	}
	contentWidth := width - 4
	if contentWidth < minWidth-4 {
		contentWidth = minWidth - 4
	}
	styleWidth := contentWidth + 2

	var lines []string
	lines = append(lines, styleCyanBold.Render("m2herd settings")+" "+styleDim.Render("(esc to dashboard)"))
	if sv.loading {
		lines = append(lines, "", styleDim.Render("loading settings.json …"))
	} else if sv.err != nil {
		lines = append(lines, "", styleRed.Render("settings.json: "+sv.err.Error()))
	} else {
		lines = append(lines, "")
		lines = append(lines, styleBold.Render("ORCHESTRATOR"))
		lines = append(lines, renderSettingsField(sv, "orchestrator", "agent", sv.settings.Orchestrator.Agent, settingsDefaults.Orchestrator.Agent))
		lines = append(lines, renderSettingsField(sv, "orchestrator", "runner", sv.settings.Orchestrator.Runner, settingsDefaults.Orchestrator.Runner))
		lines = append(lines, "")
		lines = append(lines, styleBold.Render("WORKERS"))
		lines = append(lines, renderSettingsField(sv, "workers", "agent", sv.settings.Workers.Agent, settingsDefaults.Workers.Agent))
		lines = append(lines, renderSettingsField(sv, "workers", "runner", sv.settings.Workers.Runner, settingsDefaults.Workers.Runner))
		lines = append(lines, "")
		lines = append(lines, styleBold.Render("ROUTING"))
		if len(sv.settings.Routing) == 0 {
			lines = append(lines, styleDim.Render("  (no explicit rules)"))
		}
		for i, r := range sv.settings.Routing {
			lines = append(lines, renderRulePattern(sv, i, r.Pattern))
			lines = append(lines, renderRuleAgent(sv, i, r.Agent))
			lines = append(lines, renderRuleRunner(sv, i, r.Runner))
			lines = append(lines, renderRuleModel(sv, i, r.Model))
		}
		workerDefaults := resolvedEndpoint(sv.settings.Workers, settingsDefaults.Workers)
		lines = append(lines, styleDim.Render("  fallback  "+workerDefaults.Agent+" via "+workerDefaults.Runner+" — fallback — edit in WORKERS"))
	}

	lines = append(lines, "")
	lines = append(lines, settingsFooter(sv))
	for i, l := range lines {
		lines[i] = truncLine(l, contentWidth)
	}

	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(colBorder).
		Padding(0, 1).
		Width(styleWidth)
	return box.Render(strings.Join(lines, "\n"))
}

func renderSettingsField(sv *settingsView, section, field, raw, def string) string {
	row := settingsRow{Kind: settingsRowField, Section: section, Field: field}
	return renderSettingsRow(sv, row, field, settingsValue(raw, def))
}

func renderRulePattern(sv *settingsView, idx int, pattern string) string {
	row := settingsRow{Kind: settingsRowRulePattern, Section: "routing", Field: "pattern", Rule: idx}
	return renderSettingsRow(sv, row, fmt.Sprintf("rule %d pattern", idx+1), styleBold.Render(pattern))
}

func renderRuleAgent(sv *settingsView, idx int, raw string) string {
	workerDefaults := resolvedEndpoint(sv.settings.Workers, settingsDefaults.Workers)
	row := settingsRow{Kind: settingsRowRuleAgent, Section: "routing", Field: "agent", Rule: idx}
	return renderSettingsRow(sv, row, fmt.Sprintf("rule %d agent", idx+1), settingsValue(raw, workerDefaults.Agent))
}

func renderRuleRunner(sv *settingsView, idx int, raw string) string {
	workerDefaults := resolvedEndpoint(sv.settings.Workers, settingsDefaults.Workers)
	row := settingsRow{Kind: settingsRowRuleRunner, Section: "routing", Field: "runner", Rule: idx}
	return renderSettingsRow(sv, row, fmt.Sprintf("rule %d runner", idx+1), settingsValue(raw, workerDefaults.Runner))
}

func renderRuleModel(sv *settingsView, idx int, raw string) string {
	row := settingsRow{Kind: settingsRowRuleModel, Section: "routing", Field: "model", Rule: idx}
	value := styleDim.Render("default")
	if raw != "" {
		value = styleBold.Render(raw)
	}
	return renderSettingsRow(sv, row, fmt.Sprintf("rule %d model", idx+1), value)
}

func renderSettingsRow(sv *settingsView, row settingsRow, label, value string) string {
	marker := "  "
	if current, ok := sv.currentRow(); ok && sameSettingsRow(current, row) {
		marker = styleCyanBold.Render("> ")
		return marker + styleCyanBold.Render(padRight(label, 18)) + value
	}
	return marker + styleDim.Render(padRight(label, 18)) + value
}

func settingsValue(raw, def string) string {
	if raw == "" || raw == def {
		return styleDim.Render("default (" + def + ")")
	}
	return styleBold.Render(raw)
}

func sameSettingsRow(a, b settingsRow) bool {
	return a.Kind == b.Kind && a.Section == b.Section && a.Field == b.Field && a.Rule == b.Rule
}

func settingsFooter(sv *settingsView) string {
	if sv.inputMode != settingsInputNone {
		line := styleCyanBold.Render(sv.inputPrompt+": ") + sv.inputValue + styleDim.Render("  enter save · esc discard")
		// invalid input keeps the minibuffer open — surface the red toast on
		// the same line so the feedback is visible while typing continues
		if sv.toastLive && sv.toastRed {
			line += " · " + styleRed.Render(sv.toast)
		}
		return line
	}
	if sv.confirmDelete {
		return styleRed.Render("delete rule? ") + styleBold.Render("y") + "/" + styleBold.Render("n")
	}
	hint := styleDim.Render("j/k move · enter/space edit/cycle · a add · d delete · r reset · ? help · esc back")
	if sv.toastLive {
		if sv.toastRed {
			return hint + " · " + styleRed.Render(sv.toast)
		}
		return hint + " · " + styleGreen.Render(sv.toast)
	}
	return hint
}

func inList(v string, list []string) bool {
	for _, x := range list {
		if v == x {
			return true
		}
	}
	return false
}

func cycleValue(v string, list []string) string {
	if v == "" {
		if len(list) > 1 {
			return list[1]
		}
		return list[0]
	}
	for i, x := range list {
		if v == x {
			return list[(i+1)%len(list)]
		}
	}
	return list[0]
}
