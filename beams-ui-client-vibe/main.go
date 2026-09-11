package main

import (
	"embed"
	"io/fs"
	"log"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/mac"
)

//go:embed all:frontend
var assets embed.FS

func main() {
	sub, err := fs.Sub(assets, "frontend")
	if err != nil {
		log.Fatal(err)
	}
	app := NewApp()
	err = wails.Run(&options.App{
		Title:            "Beams",
		Width:            1320,
		Height:           860,
		MinWidth:         960,
		MinHeight:        600,
		BackgroundColour: &options.RGBA{R: 0x0e, G: 0x10, B: 0x14, A: 0xff},
		AssetServer:      &assetserver.Options{Assets: sub},
		OnStartup:        app.startup,
		Bind:             []interface{}{app},
		Mac: &mac.Options{
			TitleBar:             mac.TitleBarHiddenInset(),
			Appearance:           mac.NSAppearanceNameDarkAqua,
			WebviewIsTransparent: false,
			About: &mac.AboutInfo{
				Title:   "Beams",
				Message: "Run Claude Code inside Teleport Beams sandboxes and keep the output and memory in GitHub.",
			},
		},
	})
	if err != nil {
		log.Fatal(err)
	}
}
