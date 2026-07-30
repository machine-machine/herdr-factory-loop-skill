package main

import (
	"math/rand"
	"strings"
	"testing"
)

// finalGrid is what every effect must converge to, whatever route it takes.
func finalGrid(s *splash) []string {
	out := make([]string, s.h)
	for r := 0; r < s.h; r++ {
		row := make([]rune, s.w)
		for c := 0; c < s.w; c++ {
			row[c] = s.cellFor(r, c)
		}
		out[r] = string(row)
	}
	return out
}

func currentGrid(s *splash) []string {
	out := make([]string, s.h)
	for r := range s.cur {
		out[r] = string(s.cur[r])
	}
	return out
}

func TestWordmarkHasInk(t *testing.T) {
	g := buildWordmark()
	if len(g) != glyphH*vScale {
		t.Fatalf("wordmark height = %d, want %d", len(g), glyphH*vScale)
	}
	wantW := len(splashWord)*(glyphW+glyphGap) - glyphGap
	if len(g[0]) != wantW {
		t.Fatalf("wordmark width = %d, want %d", len(g[0]), wantW)
	}
	ink := 0
	for _, row := range g {
		for _, on := range row {
			if on {
				ink++
			}
		}
	}
	if ink == 0 {
		t.Fatal("wordmark has no ink — the font lookup silently missed every glyph")
	}
	// Every glyph in the word must actually exist in the font, or the wordmark
	// renders with holes that no test on total ink would catch.
	for _, ch := range splashWord {
		if _, ok := splashFont[ch]; !ok {
			t.Fatalf("no glyph for %q in splashFont", ch)
		}
	}
}

// Every effect must reach the finished wordmark, and do it inside the hard cap.
func TestEveryEffectConverges(t *testing.T) {
	for fx := splashEffect(0); fx < splashEffectCount; fx++ {
		t.Run(fx.String(), func(t *testing.T) {
			s := newSplashWithEffect(fx, rand.New(rand.NewSource(1)))
			frames := 0
			for !s.Tick() {
				frames++
				if frames > splashHardCapFrames+5 {
					t.Fatalf("%s never reported done; Tick() ignored the hard cap", fx)
				}
			}
			if !s.Done() {
				t.Fatalf("%s: Tick() returned true but Done() is false", fx)
			}
			if got, want := currentGrid(s), finalGrid(s); !equalRows(got, want) {
				t.Fatalf("%s did not converge to the wordmark\n got: %q\nwant: %q", fx, got, want)
			}
		})
	}
}

// The cap is the guarantee that a slow or stuck effect cannot hold the dashboard.
func TestHardCapAlwaysFinishes(t *testing.T) {
	for fx := splashEffect(0); fx < splashEffectCount; fx++ {
		s := newSplashWithEffect(fx, rand.New(rand.NewSource(7)))
		for i := 0; i < splashHardCapFrames; i++ {
			s.Tick()
		}
		if !s.Done() {
			t.Fatalf("%s still running after %d frames", fx, splashHardCapFrames)
		}
	}
}

func TestTickAfterDoneIsSafe(t *testing.T) {
	s := newSplashWithEffect(fxScanline, rand.New(rand.NewSource(3)))
	s.Finish()
	if !s.Tick() {
		t.Fatal("Tick() on a finished splash must stay finished")
	}
}

func TestViewFitsNarrowAndWideTerminals(t *testing.T) {
	s := newSplashWithEffect(fxTypewriter, rand.New(rand.NewSource(5)))
	s.Finish()
	for _, w := range []int{0, 10, 40, 200} {
		out := s.View(w, 24)
		if out == "" {
			t.Fatalf("width %d produced an empty view", w)
		}
		if !strings.Contains(out, "the factory loop") {
			t.Fatalf("width %d dropped the tagline", w)
		}
	}
}

func TestShortTerminalDropsTopPadding(t *testing.T) {
	s := newSplashWithEffect(fxTypewriter, rand.New(rand.NewSource(5)))
	s.Finish()
	tall := s.View(80, 40)
	short := s.View(80, 8)
	if !strings.HasPrefix(tall, "\n\n") {
		t.Fatal("tall terminal should get top padding")
	}
	if strings.HasPrefix(short, "\n\n") {
		t.Fatal("short terminal should not get top padding")
	}
}

func TestRandomEffectIsInRange(t *testing.T) {
	for seed := int64(0); seed < 50; seed++ {
		s := newSplash(seed)
		if s.effect < 0 || s.effect >= splashEffectCount {
			t.Fatalf("seed %d produced out-of-range effect %d", seed, s.effect)
		}
		if s.effect.String() == "unknown" {
			t.Fatalf("seed %d produced an unnamed effect", seed)
		}
	}
}

func equalRows(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
