package main

// splash.go — the m2herd-tui startup reveal.
//
// The effect SET and the half-block rendering technique are borrowed from pi
// (@earendil-works/pi-coding-agent, MIT) — see its
// dist/modes/interactive/components/armin.js, which reveals XBM art with one of
// seven randomly chosen effects. The art here is our own wordmark and the state
// machines are a fresh Go implementation; only the idea travelled.
//
// Doctrine: this is a read-only decoration. It touches no fabric file, it never
// runs in `--once` (hooks and CI must keep getting a clean single frame), and any
// keypress dismisses it. It also self-terminates, so a slow terminal cannot leave
// the dashboard stuck behind an animation.

import (
	"math/rand"
	"os"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// 5x7 glyphs, '#' = ink. Uppercase only: the wordmark needs exactly these six.
var splashFont = map[rune][]string{
	'M': {"#...#", "##.##", "#.#.#", "#...#", "#...#", "#...#", "#...#"},
	'2': {".###.", "#...#", "....#", "..##.", ".#...", "#....", "#####"},
	'H': {"#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"},
	'E': {"#####", "#....", "#....", "####.", "#....", "#....", "#####"},
	'R': {"####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"},
	'D': {"####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."},
}

const (
	splashWord = "M2HERD"
	glyphW     = 5
	glyphH     = 7
	glyphGap   = 1
	// Each source pixel becomes 2 rows so the half-block packing has something to
	// pack; without it a 7-row bitmap collapses to 4 squashed display rows.
	vScale = 2
)

// splashEffect is the reveal style. All seven are ported; one is picked at random
// per launch, which is the whole charm of the original.
type splashEffect int

const (
	fxTypewriter splashEffect = iota
	fxScanline
	fxRain
	fxFade
	fxCRT
	fxGlitch
	fxDissolve
	splashEffectCount
)

var splashEffectNames = [splashEffectCount]string{
	"typewriter", "scanline", "rain", "fade", "crt", "glitch", "dissolve",
}

func (e splashEffect) String() string {
	if e < 0 || e >= splashEffectCount {
		return "unknown"
	}
	return splashEffectNames[e]
}

type splashDrop struct {
	y       int
	settled int
}

// splash holds one in-flight reveal.
type splash struct {
	effect splashEffect
	w, h   int // display grid: h is already half-block rows

	target [][]bool   // ink map, vScale-expanded
	cur    [][]rune   // what we draw right now
	rnd    *rand.Rand // seeded per launch; tests inject a fixed seed

	// per-effect state
	pos       int          // typewriter
	row       int          // scanline
	drops     []splashDrop // rain
	order     [][2]int     // fade + dissolve reveal order
	idx       int          // fade + dissolve cursor
	expansion int          // crt
	phase     int          // glitch

	frames int  // frames elapsed, for the hard cap
	done   bool
}

type splashTickMsg time.Time

// splashDisabled reports whether the reveal must be skipped entirely.
// M2HERD_NO_SPLASH=1 opts out; a non-tty stdout means we are piped, and a piped
// animation is noise. M2HERD_NO_TUI already routes elsewhere before we get here.
func splashDisabled() bool {
	if os.Getenv("M2HERD_NO_SPLASH") == "1" {
		return true
	}
	fi, err := os.Stdout.Stat()
	if err != nil {
		return true
	}
	return fi.Mode()&os.ModeCharDevice == 0
}

func newSplash(seed int64) *splash {
	rnd := rand.New(rand.NewSource(seed))
	return newSplashWithEffect(splashEffect(rnd.Intn(int(splashEffectCount))), rnd)
}

func newSplashWithEffect(fx splashEffect, rnd *rand.Rand) *splash {
	target := buildWordmark()
	h := len(target) / 2
	w := 0
	if len(target) > 0 {
		w = len(target[0])
	}
	s := &splash{effect: fx, w: w, h: h, target: target, rnd: rnd}
	s.cur = make([][]rune, h)
	for r := range s.cur {
		s.cur[r] = make([]rune, w)
		for c := range s.cur[r] {
			s.cur[r][c] = ' '
		}
	}
	s.initEffect()
	return s
}

// buildWordmark renders splashWord into a vScale-expanded ink map.
func buildWordmark() [][]bool {
	width := len(splashWord)*(glyphW+glyphGap) - glyphGap
	rows := make([][]bool, 0, glyphH*vScale)
	for y := 0; y < glyphH; y++ {
		line := make([]bool, width)
		x := 0
		for _, ch := range splashWord {
			g, ok := splashFont[ch]
			if !ok {
				x += glyphW + glyphGap
				continue
			}
			for i := 0; i < glyphW; i++ {
				if g[y][i] == '#' {
					line[x+i] = true
				}
			}
			x += glyphW + glyphGap
		}
		// vScale copies, so half-block packing has real pairs to work with.
		for v := 0; v < vScale; v++ {
			dup := make([]bool, width)
			copy(dup, line)
			rows = append(rows, dup)
		}
	}
	return rows
}

// cellFor packs two vertical ink pixels into one half-block rune.
func (s *splash) cellFor(row, x int) rune {
	upper := s.ink(row*2, x)
	lower := s.ink(row*2+1, x)
	switch {
	case upper && lower:
		return '█'
	case upper:
		return '▀'
	case lower:
		return '▄'
	}
	return ' '
}

func (s *splash) ink(y, x int) bool {
	if y < 0 || y >= len(s.target) || x < 0 || x >= s.w {
		return false
	}
	return s.target[y][x]
}

func (s *splash) initEffect() {
	switch s.effect {
	case fxRain:
		s.drops = make([]splashDrop, s.w)
		for i := range s.drops {
			s.drops[i] = splashDrop{y: -s.rnd.Intn(s.h*2 + 1)}
		}
	case fxFade, fxDissolve:
		s.order = make([][2]int, 0, s.w*s.h)
		for r := 0; r < s.h; r++ {
			for c := 0; c < s.w; c++ {
				s.order = append(s.order, [2]int{r, c})
			}
		}
		s.rnd.Shuffle(len(s.order), func(i, j int) { s.order[i], s.order[j] = s.order[j], s.order[i] })
		if s.effect == fxDissolve {
			noise := []rune{' ', '░', '▒', '▓', '█', '▀', '▄'}
			for r := range s.cur {
				for c := range s.cur[r] {
					s.cur[r][c] = noise[s.rnd.Intn(len(noise))]
				}
			}
		}
	case fxGlitch:
		s.phase = 0
	}
}

// FPS is per-effect: glitch reads as jitter only when it runs fast.
func (s *splash) fps() int {
	if s.effect == fxGlitch {
		return 60
	}
	return 30
}

// splashHardCapFrames bounds any reveal to ~1.6s at 30fps. A stuck effect must
// never hold the dashboard hostage.
const splashHardCapFrames = 48

func (s *splash) Done() bool { return s.done }

// Tick advances one frame and reports whether the reveal has finished.
func (s *splash) Tick() bool {
	if s.done {
		return true
	}
	s.frames++
	finished := false
	switch s.effect {
	case fxTypewriter:
		finished = s.tickTypewriter()
	case fxScanline:
		finished = s.tickScanline()
	case fxRain:
		finished = s.tickRain()
	case fxFade:
		finished = s.tickReveal()
	case fxCRT:
		finished = s.tickCRT()
	case fxGlitch:
		finished = s.tickGlitch()
	case fxDissolve:
		finished = s.tickReveal()
	default:
		finished = true
	}
	if finished || s.frames >= splashHardCapFrames {
		s.Finish()
		return true
	}
	return false
}

// Finish snaps to the completed wordmark and stops the animation.
func (s *splash) Finish() {
	for r := 0; r < s.h; r++ {
		for c := 0; c < s.w; c++ {
			s.cur[r][c] = s.cellFor(r, c)
		}
	}
	s.done = true
}

func (s *splash) tickTypewriter() bool {
	const perFrame = 12
	total := s.w * s.h
	for i := 0; i < perFrame && s.pos < total; i++ {
		r, c := s.pos/s.w, s.pos%s.w
		s.cur[r][c] = s.cellFor(r, c)
		s.pos++
	}
	return s.pos >= total
}

func (s *splash) tickScanline() bool {
	if s.row >= s.h {
		return true
	}
	for c := 0; c < s.w; c++ {
		s.cur[s.row][c] = s.cellFor(s.row, c)
	}
	s.row++
	return s.row >= s.h
}

func (s *splash) tickRain() bool {
	settledAll := true
	for c := 0; c < s.w; c++ {
		d := &s.drops[c]
		if d.settled >= s.h {
			continue
		}
		settledAll = false
		d.y++
		// clear the previous head so the drop reads as falling, not smearing
		if prev := d.y - 1; prev >= 0 && prev < s.h && prev >= d.settled {
			s.cur[prev][c] = ' '
		}
		if d.y >= s.h-d.settled {
			// landed: freeze this cell and start the next drop above it
			row := s.h - 1 - d.settled
			if row >= 0 {
				s.cur[row][c] = s.cellFor(row, c)
			}
			d.settled++
			d.y = -1
			continue
		}
		if d.y >= 0 && d.y < s.h {
			s.cur[d.y][c] = '▖'
		}
	}
	return settledAll
}

// tickReveal serves fade and dissolve: both walk a shuffled cell order, they
// only differ in what the grid looked like before they started.
func (s *splash) tickReveal() bool {
	perFrame := len(s.order)/20 + 1
	for i := 0; i < perFrame && s.idx < len(s.order); i++ {
		rc := s.order[s.idx]
		s.cur[rc[0]][rc[1]] = s.cellFor(rc[0], rc[1])
		s.idx++
	}
	return s.idx >= len(s.order)
}

// tickCRT opens from the vertical centre outward, like a tube warming up.
func (s *splash) tickCRT() bool {
	mid := s.h / 2
	for _, r := range []int{mid - s.expansion, mid + s.expansion} {
		if r < 0 || r >= s.h {
			continue
		}
		for c := 0; c < s.w; c++ {
			s.cur[r][c] = s.cellFor(r, c)
		}
	}
	s.expansion++
	return s.expansion > s.h/2+1
}

// tickGlitch jitters rows horizontally, then settles them one by one.
func (s *splash) tickGlitch() bool {
	const glitchFrames = 10
	s.phase++
	if s.phase <= glitchFrames {
		for r := 0; r < s.h; r++ {
			shift := s.rnd.Intn(7) - 3
			for c := 0; c < s.w; c++ {
				src := c + shift
				if src < 0 || src >= s.w {
					s.cur[r][c] = ' '
					continue
				}
				s.cur[r][c] = s.cellFor(r, src)
			}
		}
		return false
	}
	settle := s.phase - glitchFrames - 1
	if settle >= s.h {
		return true
	}
	for c := 0; c < s.w; c++ {
		s.cur[settle][c] = s.cellFor(settle, c)
	}
	return settle >= s.h-1
}

// View renders the current frame, centred, with the tagline underneath.
func (s *splash) View(width, height int) string {
	if width <= 0 {
		width = s.w
	}
	pad := 0
	if width > s.w {
		pad = (width - s.w) / 2
	}
	lead := strings.Repeat(" ", pad)

	var b strings.Builder
	// A little vertical breathing room, but never more than the terminal has.
	top := 2
	if height > 0 && height < s.h+6 {
		top = 0
	}
	for i := 0; i < top; i++ {
		b.WriteByte('\n')
	}
	for _, row := range s.cur {
		b.WriteString(lead)
		b.WriteString(styleCyanBold.Render(strings.TrimRight(string(row), " ")))
		b.WriteByte('\n')
	}
	tag := "the factory loop"
	tagPad := 0
	if width > len(tag) {
		tagPad = (width - len(tag)) / 2
	}
	b.WriteByte('\n')
	b.WriteString(strings.Repeat(" ", tagPad))
	b.WriteString(styleDim.Render(tag))
	return b.String()
}

func splashTickCmd(fps int) tea.Cmd {
	if fps <= 0 {
		fps = 30
	}
	d := time.Second / time.Duration(fps)
	return tea.Tick(d, func(t time.Time) tea.Msg { return splashTickMsg(t) })
}
