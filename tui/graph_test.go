package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadGraph(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		wantErr    bool
		wantLevels map[string]int
		wantCycle  bool
	}{
		{
			name: "valid graph",
			body: `{"schema_version":1,"nodes":[
				{"id":"base","kind":"slice","owns":["base.go"]},
				{"id":"ship","kind":"gate","owns":[]}
			],"edges":[{"from":"ship","to":"base","type":"depends_on"}]}`,
			wantLevels: map[string]int{"base": 0, "ship": 1},
		},
		{name: "absent file", wantErr: true},
		{name: "malformed JSON", body: `{`, wantErr: true},
		{
			name:    "unknown edge type",
			body:    `{"nodes":[{"id":"a","kind":"slice"}],"edges":[{"from":"a","to":"a","type":"supersedes"}]}`,
			wantErr: true,
		},
		{
			name: "declared cycle",
			body: `{"nodes":[{"id":"a","kind":"slice"},{"id":"b","kind":"slice"}],
				"edges":[
					{"from":"a","to":"b","type":"depends_on","max_traversals":1},
					{"from":"b","to":"a","type":"depends_on","max_traversals":1}
				]}`,
			wantLevels: map[string]int{"a": 1, "b": 1},
			wantCycle:  true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.MkdirAll(filepath.Join(dir, ".m2herd"), 0o755); err != nil {
				t.Fatal(err)
			}
			if tt.body != "" {
				if err := os.WriteFile(filepath.Join(dir, ".m2herd", "graph.json"), []byte(tt.body), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			g, err := LoadGraph(dir)
			if (err != nil) != tt.wantErr {
				t.Fatalf("LoadGraph error = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr {
				return
			}
			if len(g.Nodes) == 0 {
				t.Fatal("parsed graph has no nodes")
			}
			for id, want := range tt.wantLevels {
				if got := g.Levels[id]; got != want {
					t.Errorf("level[%s] = %d, want %d", id, got, want)
				}
			}
			if tt.wantCycle && (!g.Cyclic["a"] || !g.Cyclic["b"]) {
				t.Errorf("cycle nodes not marked: %#v", g.Cyclic)
			}
		})
	}
}

func TestNodeWithoutWorkerIsPending(t *testing.T) {
	ov := &Overview{Workers: []Worker{{Slice: "other", State: "done"}}}
	if got := graphNodeState(ov, "unclaimed"); got != "pending" {
		t.Fatalf("graphNodeState = %q, want pending", got)
	}
	snap := &Snapshot{
		Overview: ov,
		Graph: &Graph{
			Nodes:  []GraphNode{{ID: "unclaimed", Kind: "slice"}},
			Levels: map[string]int{"unclaimed": 0},
			Cyclic: map[string]bool{},
		},
		GraphTraces: map[string]SliceTrace{},
	}
	if got := RenderGraph(snap, 80, 0); !strings.Contains(got, "state: pending") {
		t.Fatalf("pending state missing from render:\n%s", got)
	}
}
