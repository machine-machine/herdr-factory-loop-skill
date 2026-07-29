package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

func RenderGraph(s *Snapshot, width, cursor int) string {
	if width < minWidth {
		width = minWidth
	}
	contentWidth := width - 4
	lines := []string{
		styleCyanBold.Render("GRAPH") + "  " + styleDim.Render("depends_on: A waits on B · caused: A ⇢ B (provenance only)"),
		"",
	}
	if s == nil || s.Graph == nil || len(s.Graph.Nodes) == 0 {
		lines = append(lines, styleDim.Render("  (no graph declared)"), "",
			styleDim.Render("read-only · [g/esc] dashboard [?] help"))
		return graphBox(lines, contentWidth)
	}
	g := s.Graph
	if cursor < 0 || cursor >= len(g.Nodes) {
		cursor = 0
	}
	nodesAt := map[int][]int{}
	var levels []int
	seenLevel := map[int]bool{}
	for i, n := range g.Nodes {
		level := g.Levels[n.ID]
		nodesAt[level] = append(nodesAt[level], i)
		if !seenLevel[level] {
			levels = append(levels, level)
			seenLevel[level] = true
		}
	}
	sort.Ints(levels)
	for _, level := range levels {
		title := fmt.Sprintf("TIER %d", level)
		for _, idx := range nodesAt[level] {
			if g.Cyclic[g.Nodes[idx].ID] {
				title += "  " + styleYellow.Render("(bounded cycle / cycle-blocked)")
				break
			}
		}
		lines = append(lines, styleBold.Render(title))
		for _, idx := range nodesAt[level] {
			n := g.Nodes[idx]
			state := graphNodeState(s.Overview, n.ID)
			prefix := "  "
			if idx == cursor {
				prefix = styleCyanBold.Render("› ")
			}
			kind := ""
			if n.Kind != "slice" {
				kind = styleDim.Render(" [" + n.Kind + " · not dispatchable]")
			}
			lines = append(lines, prefix+stateStyle(state).Render(stateGlyph(state)+" "+n.ID)+"  "+n.Summary+kind)
			var waits, caused []string
			for _, e := range g.Edges {
				if e.From != n.ID {
					continue
				}
				if e.Type == "depends_on" {
					label := e.To
					if e.MaxTraversals != nil {
						label += fmt.Sprintf(" (max %d)", *e.MaxTraversals)
					}
					waits = append(waits, label)
				} else {
					caused = append(caused, e.To)
				}
			}
			if len(waits) > 0 {
				lines = append(lines, "      waits on: "+strings.Join(waits, ", "))
			}
			if len(caused) > 0 {
				lines = append(lines, styleDim.Render("      caused ⇢ "+strings.Join(caused, ", ")+" (provenance)"))
			}
		}
		lines = append(lines, "")
	}
	n := g.Nodes[cursor]
	lines = append(lines, styleBold.Render("DETAIL · "+n.ID))
	lines = append(lines, "  kind: "+n.Kind+dispatchability(n.Kind))
	lines = append(lines, "  state: "+graphNodeState(s.Overview, n.ID))
	lines = append(lines, "  owns: "+missingIfEmpty(strings.Join(n.Owns, ", ")))
	lines = append(lines, "  area: "+missingIfEmpty(n.Area))
	trace := s.GraphTraces[n.ID]
	if !trace.Present {
		lines = append(lines, "  latest trace: "+styleDim.Render("missing"))
	} else {
		lines = append(lines, "  latest trace: "+trace.RunID)
		lines = append(lines, "    tokens: "+numberOrMissing(trace.Tokens)+" · cost_usd: "+numberOrMissing(trace.CostUSD))
		lines = append(lines, "    dispatched_at: "+missingIfEmpty(trace.Dispatched))
		lines = append(lines, "    collected_at: "+missingIfEmpty(trace.Collected))
	}
	lines = append(lines, "", styleDim.Render("read-only · [j/k ↑/↓] select [g/esc] dashboard [?] help"))
	return graphBox(lines, contentWidth)
}

func graphBox(lines []string, contentWidth int) string {
	for i, line := range lines {
		lines[i] = truncLine(line, contentWidth)
	}
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(colBorder).
		Padding(0, 1).
		Width(contentWidth + 2).
		Render(strings.Join(lines, "\n"))
}

func stateGlyph(state string) string {
	switch state {
	case "done":
		return "✓"
	case "working":
		return "●"
	case "spawned":
		return "◐"
	case "failed":
		return "✗"
	case "down":
		return "↓"
	default:
		return "○"
	}
}

func dispatchability(kind string) string {
	if kind == "slice" {
		return ""
	}
	return " (not dispatchable)"
}

func missingIfEmpty(value string) string {
	if strings.TrimSpace(value) == "" {
		return styleDim.Render("missing")
	}
	return value
}

func numberOrMissing(value *json.Number) string {
	if value == nil {
		return styleDim.Render("missing")
	}
	return value.String()
}
