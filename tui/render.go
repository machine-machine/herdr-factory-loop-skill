package main

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/mattn/go-runewidth"
)

// Snapshot is one fully-gathered read of the fabric — everything Render needs,
// collected up front so a frame renders from static data (no I/O in Render).
type Snapshot struct {
	Dir        string
	Overview   *Overview
	DriftClean bool
	Missing    []string
	Orphan     []string
	Next       string
	NextOK     bool
	Budget     BudgetInfo
	Update     UpdateBanner
	Notes      []NoteLine
	AreaAges   map[string]string
	Agents     map[string]string
	AgentsOK   bool
	Warnings   []string
}

// BuildSnapshot gathers every read-only data source in one pass.
func BuildSnapshot(dir string) (*Snapshot, error) {
	ov, err := LoadOverview(dir)
	if err != nil {
		return nil, err
	}
	var warnings []string
	clean, missing, orphan, driftErr := Drift(dir, ov)
	if driftErr != nil {
		warnings = append(warnings, "drift check skipped: "+driftErr.Error())
	}
	next, nextOK := NextLine(dir)
	ages := make(map[string]string, len(ov.Areas))
	for _, a := range ov.Areas {
		ages[a.Name] = AreaAge(dir, a.Name)
	}
	agents, agentsOK := HerdrAgents()
	return &Snapshot{
		Dir:        dir,
		Overview:   ov,
		DriftClean: clean,
		Missing:    missing,
		Orphan:     orphan,
		Next:       next,
		NextOK:     nextOK,
		Budget:     LoadBudget(),
		Update:     LoadUpdateBanner(),
		Notes:      NotesTail(dir, 5),
		AreaAges:   ages,
		Agents:     agents,
		AgentsOK:   agentsOK,
		Warnings:   warnings,
	}, nil
}

// ---------- palette (adaptive: readable on light and dark backgrounds) --------

var (
	colDim     = lipgloss.AdaptiveColor{Light: "245", Dark: "243"}
	colGreen   = lipgloss.AdaptiveColor{Light: "28", Dark: "84"}
	colYellow  = lipgloss.AdaptiveColor{Light: "136", Dark: "221"}
	colRed     = lipgloss.AdaptiveColor{Light: "124", Dark: "203"}
	colCyan    = lipgloss.AdaptiveColor{Light: "30", Dark: "87"}
	colMagenta = lipgloss.AdaptiveColor{Light: "91", Dark: "212"}
	colBorder  = lipgloss.AdaptiveColor{Light: "252", Dark: "238"}

	styleDim      = lipgloss.NewStyle().Foreground(colDim)
	styleBold     = lipgloss.NewStyle().Bold(true)
	styleGreen    = lipgloss.NewStyle().Foreground(colGreen)
	styleYellow   = lipgloss.NewStyle().Foreground(colYellow)
	styleRed      = lipgloss.NewStyle().Foreground(colRed)
	styleCyanBold = lipgloss.NewStyle().Foreground(colCyan).Bold(true)
	styleNext     = lipgloss.NewStyle().Foreground(colMagenta).Bold(true)
)

const minWidth = 40
const wideThreshold = 100
const areasColWidth = 46

// padRight pads/truncates plain text to an exact cell width using correct
// Unicode cell widths (mattn/go-runewidth) — apply color styling *after*
// padding so escape codes never skew the measured width.
func padRight(s string, w int) string {
	if w <= 0 {
		return ""
	}
	cw := runewidth.StringWidth(s)
	if cw > w {
		return runewidth.Truncate(s, w, "")
	}
	return s + strings.Repeat(" ", w-cw)
}

// padLine pads possibly-styled text to a cell width; lipgloss.Width strips
// ANSI escapes before measuring, so styled rows still align.
func padLine(s string, w int) string {
	cw := lipgloss.Width(s)
	if cw >= w {
		return s
	}
	return s + strings.Repeat(" ", w-cw)
}

// truncLine truncates possibly-styled text to a cell width with an ellipsis,
// keeping escape sequences intact (ansi.Truncate is ANSI-aware).
func truncLine(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if lipgloss.Width(s) <= w {
		return s
	}
	return ansi.Truncate(s, w, "…")
}

// Render draws one full frame at the given terminal width.
func Render(s *Snapshot, width int) string {
	if width < minWidth {
		width = minWidth
	}
	// lipgloss Style.Width() sizes the padding+text area *inside* the border,
	// which is then drawn on top — so a style rendering to a total width of
	// `width` needs Width(width-2) and leaves (width-2)-2(padding) for text.
	contentWidth := width - 4
	if contentWidth < minWidth-4 {
		contentWidth = minWidth - 4
	}
	styleWidth := contentWidth + 2

	var lines []string
	lines = append(lines, headerLine(s, contentWidth))
	lines = append(lines, styleDim.Render(padRight("goal:", 11))+valueOr(s.Overview.Goal, "(none)"))
	lines = append(lines, styleDim.Render(padRight("done_when:", 11))+valueOr(s.Overview.DoneWhen, "(not coached)"))
	if row := driftRow(s); row != "" {
		lines = append(lines, row)
	}
	for _, w := range s.Warnings {
		lines = append(lines, styleYellow.Render(padRight("warning:", 11)+w))
	}
	if row := budgetRow(s.Budget); row != "" {
		lines = append(lines, row)
	}
	if s.Update.Show {
		lines = append(lines, styleYellow.Render(fmt.Sprintf("update:    %d commit(s) behind — run: m2herd self-update", s.Update.Behind)))
	}
	lines = append(lines, "")
	lines = append(lines, nextLine(s))
	lines = append(lines, "")

	areas := areasBlock(s)
	var workers []string
	if len(s.Overview.Workers) > 0 {
		workers = workersBlock(s)
	}
	if len(workers) > 0 && width >= wideThreshold {
		left := make([]string, len(areas))
		for i, l := range areas {
			left[i] = padLine(truncLine(l, areasColWidth-1), areasColWidth)
		}
		lines = append(lines, strings.Split(lipgloss.JoinHorizontal(lipgloss.Top, strings.Join(left, "\n"), strings.Join(workers, "\n")), "\n")...)
	} else {
		lines = append(lines, areas...)
		if len(workers) > 0 {
			lines = append(lines, "")
			lines = append(lines, workers...)
		}
	}

	if len(s.Overview.OpenQuestions) > 0 {
		lines = append(lines, "")
		lines = append(lines, styleBold.Render("OPEN QUESTIONS"))
		for _, q := range s.Overview.OpenQuestions {
			lines = append(lines, "  - "+q)
		}
	}

	lines = append(lines, "")
	lines = append(lines, notesBlock(s)...)

	lines = append(lines, "")
	lines = append(lines, styleDim.Render("read-only · [r]esume [s]teer [q]uit"))

	// Long values (goal, done_when, notes, branches, …) must not wrap inside
	// the box — a wrapped line breaks the border and the two-column layout.
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

func valueOr(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

func headerLine(s *Snapshot, width int) string {
	repo := filepath.Base(s.Dir)
	left := styleCyanBold.Render("m2herd") + " · " + styleBold.Render(repo)

	status := s.Overview.Status
	if status == "" {
		status = "active"
	}
	var dot, statusText string
	switch status {
	case "active":
		dot, statusText = styleGreen.Render("●"), styleGreen.Render(status)
	case "paused":
		dot, statusText = styleYellow.Render("●"), styleYellow.Render(status)
	default:
		dot, statusText = "●", status
	}
	driftMark := styleGreen.Render("✓")
	if !s.DriftClean {
		driftMark = styleYellow.Render("◐")
	}
	right := dot + " " + statusText + " · drift " + driftMark

	fill := width - lipgloss.Width(left) - lipgloss.Width(right) - 2
	if fill < 1 {
		fill = 1
	}
	return left + " " + strings.Repeat("─", fill) + " " + right
}

// driftRow lists the drifted area names compactly; the header only shows ◐.
func driftRow(s *Snapshot) string {
	if s.DriftClean {
		return ""
	}
	var parts []string
	if len(s.Missing) > 0 {
		parts = append(parts, "missing: "+strings.Join(s.Missing, ", "))
	}
	if len(s.Orphan) > 0 {
		parts = append(parts, "orphan: "+strings.Join(s.Orphan, ", "))
	}
	return styleYellow.Render(padRight("drift:", 11) + strings.Join(parts, " · "))
}

func budgetRow(b BudgetInfo) string {
	if !b.Present {
		return ""
	}
	pct := b.Pct
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	filled := pct * 20 / 100
	bar := strings.Repeat("█", filled) + strings.Repeat("░", 20-filled)
	barStyle := styleGreen
	switch {
	case pct >= 90:
		barStyle = styleRed
	case pct >= 70:
		barStyle = styleYellow
	}
	return styleDim.Render(padRight("budget:", 11)) + barStyle.Render(bar) +
		fmt.Sprintf(" %d%% of %d · updated %s ago", pct, b.Budget, b.Age)
}

func nextLine(s *Snapshot) string {
	prefix := styleNext.Render("NEXT:")
	if !s.NextOK {
		return prefix + " " + styleDim.Render("(m2herd next unavailable)")
	}
	rest := strings.TrimSpace(strings.TrimPrefix(s.Next, "NEXT:"))
	if rest == "" {
		rest = styleDim.Render("(m2herd next unavailable)")
	}
	return prefix + " " + rest
}

func areasBlock(s *Snapshot) []string {
	lines := []string{styleBold.Render("AREAS")}
	if len(s.Overview.Areas) == 0 {
		lines = append(lines, styleDim.Render("  (no areas yet)"))
		return lines
	}
	for _, a := range s.Overview.Areas {
		name := padRight(a.Name, 14)
		age := s.AreaAges[a.Name]
		if a.status() == "archived" {
			row := fmt.Sprintf("  %s %s  %s", name, padRight("archived", 8), age)
			lines = append(lines, styleDim.Render(row))
			continue
		}
		rel := ""
		if len(a.Related) > 0 {
			rel = "→ " + strings.Join(a.Related, ", ")
		}
		row := fmt.Sprintf("  %s %s %s %s", name, styleGreen.Render(padRight("active", 8)), padRight(age, 5), rel)
		lines = append(lines, row)
	}
	return lines
}

func stateStyle(state string) lipgloss.Style {
	switch state {
	case "done":
		return styleGreen
	case "working", "spawned":
		return styleYellow
	case "failed":
		return styleRed
	default:
		return lipgloss.NewStyle()
	}
}

func humanizeTokens(n int64) string {
	if n >= 1000 {
		return fmt.Sprintf("%dk", n/1000)
	}
	return fmt.Sprintf("%dt", n)
}

func workersBlock(s *Snapshot) []string {
	lines := []string{styleBold.Render("WORKERS")}
	lines = append(lines, styleDim.Render("  "+padRight("slice", 10)+" "+padRight("desired", 9)+" "+padRight("observed", 10)+" "+padRight("runner", 14)+" branch"))
	for _, w := range s.Overview.Workers {
		desired := w.State
		if desired == "" {
			desired = "?"
		}
		mode := w.Mode
		if mode == "" {
			mode = "tui"
		}
		branch := w.Branch
		if branch == "" {
			branch = "-"
		}
		observed := "-"
		mark := ""
		runner := "tui"
		switch {
		case mode == "headless":
			observed = "headless"
			runner = w.Model
			if runner == "" {
				runner = "?"
			}
			if n, err := w.Tokens.Int64(); err == nil {
				runner = runner + " " + humanizeTokens(n)
			}
		case s.AgentsOK:
			st, found := s.Agents[w.PaneID]
			if !found || st == "" {
				st = "gone"
			}
			observed = st
			switch desired + ":" + observed {
			case "spawned:idle", "spawned:gone", "working:idle", "working:gone", "done:working", "failed:working":
				mark = " !"
			}
		}
		row := "  " + padRight(w.Slice, 10) + " " + stateStyle(desired).Render(padRight(desired, 9)) + " " +
			padRight(observed+mark, 10) + " " + padRight(runner, 14) + " " + branch
		lines = append(lines, row)
	}
	return lines
}

func notesBlock(s *Snapshot) []string {
	lines := []string{styleBold.Render("NOTES") + " (last 5)"}
	if len(s.Notes) == 0 {
		lines = append(lines, styleDim.Render("  (empty)"))
		return lines
	}
	for _, n := range s.Notes {
		if n.HasT {
			lines = append(lines, "  - "+styleDim.Render("["+HumanNoteTime(n.When)+"]")+" "+n.Text)
		} else {
			lines = append(lines, "  "+n.Raw)
		}
	}
	return lines
}
