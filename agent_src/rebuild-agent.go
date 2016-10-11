package main
// rebuild-agent is a lightwieght
// agent run on a Linux live system
// to collect information about the
// host machine, this information
// is then returned to the Rebuild Core
//
// Author: Liam Haworth <liam@haworth.id.au>
//

import (
	"os"
	"os/signal"
	"syscall"
	"fmt"
	"time"
	"strconv"
	"github.com/Sirupsen/logrus"
	prefixed "github.com/x-cray/logrus-prefixed-formatter"
)

// logger is used as a primary
// logging method for this agent
var logger = logrus.New()

// init is called before the main
// function to initialize the agent
// with everything it might need before
// running
func init() {
	logger.Formatter = new(prefixed.TextFormatter)
	var logLevel int64

	if os.Getenv("LOGLEVEL") == "" {
		logLevel = 4
	} else {
		logLevel, _ = strconv.ParseInt(os.Getenv("LOGLEVEL"), 10, 0)
	}

	if logLevel >= 5 {
		logger.Level = logrus.DebugLevel
	} else if logLevel >= 4 {
		logger.Level = logrus.InfoLevel
	} else {
		logger.Level = logrus.WarnLevel
	}
}

func main() {
	switch os.Args[1] {
	case "banner":
		showBanner()

	default:
		logger.Panic(fmt.Sprintf("Unknown command: %s", os.Args[1]))
	}
}

func showBanner() {
	quitHandle := make(chan os.Signal, 1)
	signal.Notify(quitHandle, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-quitHandle
		logger.Debug("The banner cannot be closed, if you really need to, please use SIGKILL")
	}()

	fmt.Println("Put some banner here")

	for { time.Sleep(10 * time.Second) }
}
