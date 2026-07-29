package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type Graph struct {
	SchemaVersion int         `json:"schema_version"`
	UpdatedAt     string      `json:"updated_at"`
	Nodes         []GraphNode `json:"nodes"`
	Edges         []GraphEdge `json:"edges"`
	Levels        map[string]int
	Cyclic        map[string]bool
}

type GraphNode struct {
	ID      string   `json:"id"`
	Kind    string   `json:"kind"`
	Owns    []string `json:"owns"`
	Area    string   `json:"area,omitempty"`
	Summary string   `json:"summary,omitempty"`
}

type GraphEdge struct {
	From          string `json:"from"`
	To            string `json:"to"`
	Type          string `json:"type"`
	MaxTraversals *int   `json:"max_traversals,omitempty"`
	Note          string `json:"note,omitempty"`
}

type SliceTrace struct {
	Present    bool
	RunID      string
	Tokens     *json.Number
	CostUSD    *json.Number
	Dispatched string
	Collected  string
}

// LoadGraph is deliberately strict about files that exist and deliberately
// harmless to its callers: BuildSnapshot treats every error like absence.
func LoadGraph(dir string) (*Graph, error) {
	b, err := os.ReadFile(filepath.Join(dir, ".m2herd", "graph.json"))
	if err != nil {
		return nil, err
	}
	var g Graph
	if err := json.Unmarshal(b, &g); err != nil {
		return nil, fmt.Errorf("graph.json: %w", err)
	}
	ids := make(map[string]bool, len(g.Nodes))
	for _, n := range g.Nodes {
		if n.ID == "" || ids[n.ID] {
			return nil, fmt.Errorf("graph.json: empty or duplicate node id %q", n.ID)
		}
		if n.Kind != "slice" && n.Kind != "gate" && n.Kind != "human" {
			return nil, fmt.Errorf("graph.json: unknown node kind %q", n.Kind)
		}
		ids[n.ID] = true
	}
	for _, e := range g.Edges {
		if e.Type != "depends_on" && e.Type != "caused" {
			return nil, fmt.Errorf("graph.json: unknown edge type %q", e.Type)
		}
		if !ids[e.From] || !ids[e.To] {
			return nil, fmt.Errorf("graph.json: edge references unknown node")
		}
	}
	g.Levels, g.Cyclic = AssignGraphLevels(g.Nodes, g.Edges)
	return &g, nil
}

// AssignGraphLevels runs Kahn's algorithm over dependency edges, treating
// "A depends on B" as the layout arc B -> A. Nodes left after the finite queue
// pass are members of, or blocked by, a cycle and share one final tier.
func AssignGraphLevels(nodes []GraphNode, edges []GraphEdge) (map[string]int, map[string]bool) {
	level := make(map[string]int, len(nodes))
	indegree := make(map[string]int, len(nodes))
	dependents := make(map[string][]string)
	for _, n := range nodes {
		indegree[n.ID] = 0
	}
	for _, e := range edges {
		if e.Type != "depends_on" {
			continue
		}
		indegree[e.From]++
		dependents[e.To] = append(dependents[e.To], e.From)
	}
	var queue []string
	for _, n := range nodes {
		if indegree[n.ID] == 0 {
			queue = append(queue, n.ID)
		}
	}
	processed := map[string]bool{}
	maxLevel := 0
	for len(queue) > 0 {
		id := queue[0]
		queue = queue[1:]
		processed[id] = true
		if level[id] > maxLevel {
			maxLevel = level[id]
		}
		for _, dependent := range dependents[id] {
			if level[dependent] < level[id]+1 {
				level[dependent] = level[id] + 1
			}
			indegree[dependent]--
			if indegree[dependent] == 0 {
				queue = append(queue, dependent)
			}
		}
	}
	cyclic := map[string]bool{}
	for _, n := range nodes {
		if !processed[n.ID] {
			level[n.ID] = maxLevel + 1
			cyclic[n.ID] = true
		}
	}
	return level, cyclic
}

func graphNodeState(ov *Overview, id string) string {
	for _, w := range ov.Workers {
		if w.Slice == id {
			if w.State == "" {
				return "pending"
			}
			return w.State
		}
	}
	return "pending"
}

// LatestSliceTrace scans run ids newest-first. Missing numeric fields remain
// nil so the detail renderer cannot accidentally present them as zero.
func LatestSliceTrace(dir, slice string) SliceTrace {
	entries, err := os.ReadDir(filepath.Join(dir, ".m2herd", "runs"))
	if err != nil {
		return SliceTrace{}
	}
	var runs []string
	for _, e := range entries {
		if e.IsDir() {
			runs = append(runs, e.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(runs)))
	for _, run := range runs {
		path := filepath.Join(dir, ".m2herd", "runs", run, "slices", slice, "status.json")
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var raw map[string]json.RawMessage
		if json.Unmarshal(b, &raw) != nil {
			continue
		}
		trace := SliceTrace{Present: true, RunID: run}
		decodeString := func(key string) string {
			var value string
			_ = json.Unmarshal(raw[key], &value)
			return value
		}
		trace.Dispatched = decodeString("dispatched_at")
		trace.Collected = decodeString("collected_at")
		for key, dst := range map[string]**json.Number{"tokens": &trace.Tokens, "cost_usd": &trace.CostUSD} {
			if value, ok := raw[key]; ok && strings.TrimSpace(string(value)) != "null" {
				n := json.Number(strings.TrimSpace(string(value)))
				*dst = &n
			}
		}
		return trace
	}
	return SliceTrace{}
}
