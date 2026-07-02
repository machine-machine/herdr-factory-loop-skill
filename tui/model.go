package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const tickInterval = 2 * time.Second

type model struct {
	dir    string
	width  int
	height int

	snap *Snapshot
	err  error

	showResume bool
	resumeVP   viewport.Model
}

func newModel(dir string) model {
	return model{dir: dir, width: 100, height: 40}
}

type snapshotMsg struct {
	snap *Snapshot
	err  error
}

type tickMsg time.Time

type resumeLoadedMsg struct {
	content string
	err     error
}

type editorFinishedMsg struct{ err error }

func loadSnapshotCmd(dir string) tea.Cmd {
	return func() tea.Msg {
		snap, err := BuildSnapshot(dir)
		return snapshotMsg{snap: snap, err: err}
	}
}

func tickCmd() tea.Cmd {
	return tea.Tick(tickInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func loadResumeCmd(dir string) tea.Cmd {
	return func() tea.Msg {
		content, err := ReadResume(dir)
		return resumeLoadedMsg{content: content, err: err}
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(loadSnapshotCmd(m.dir), tickCmd())
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.resumeVP.Width = msg.Width - 4
		m.resumeVP.Height = msg.Height - 4
		return m, nil

	case tea.KeyMsg:
		if m.showResume {
			switch msg.String() {
			case "esc", "q":
				m.showResume = false
				return m, nil
			}
			var cmd tea.Cmd
			m.resumeVP, cmd = m.resumeVP.Update(msg)
			return m, cmd
		}
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "r":
			return m, loadResumeCmd(m.dir)
		case "s":
			return m, suspendForSteerCmd(m.dir)
		}
		return m, nil

	case snapshotMsg:
		if msg.err == nil {
			m.snap = msg.snap
		}
		m.err = msg.err
		return m, nil

	case tickMsg:
		return m, tea.Batch(loadSnapshotCmd(m.dir), tickCmd())

	case resumeLoadedMsg:
		vp := viewport.New(m.width-4, m.height-4)
		if msg.err != nil {
			vp.SetContent("(could not read RESUME.md: " + msg.err.Error() + ")")
		} else {
			vp.SetContent(msg.content)
		}
		m.resumeVP = vp
		m.showResume = true
		return m, nil

	case editorFinishedMsg:
		return m, loadSnapshotCmd(m.dir)
	}
	return m, nil
}

func suspendForSteerCmd(dir string) tea.Cmd {
	editor := os.Getenv("EDITOR")
	if editor == "" {
		editor = "vi"
	}
	path := filepath.Join(dir, ".m2herd", "inbox", "STEER.md")
	c := exec.Command(editor, path)
	return tea.ExecProcess(c, func(err error) tea.Msg { return editorFinishedMsg{err: err} })
}

func (m model) View() string {
	if m.showResume {
		title := styleBold.Render("RESUME.md") + "  " + styleDim.Render("(esc to close)")
		box := lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(colBorder).
			Padding(0, 1).
			Width(m.width - 2)
		return box.Render(title + "\n\n" + m.resumeVP.View())
	}
	if m.err != nil {
		return styleRed.Render("m2herd-tui: " + m.err.Error())
	}
	if m.snap == nil {
		return styleDim.Render("m2herd-tui: loading …")
	}
	return Render(m.snap, m.width)
}
