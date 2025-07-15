package main

import (
	"fmt"
	"os"
	"os/exec"
)

func main() {
	useValidator := true // adapt to measure Validator version
	var cmd (*exec.Cmd)
	for num_bidder := 1; num_bidder <= 5; num_bidder++ {

		for i := 1; i <= 1; i++ { // adapt iterations to run multiple times
			fmt.Printf("Starting iteration %d...\n", i)
			if useValidator {
				cmd = exec.Command("go", "run", "src/ValidatorVersion/main.go", fmt.Sprint(num_bidder))
			} else {
				cmd = exec.Command("go", "run", "main.go", fmt.Sprint(num_bidder))
			}
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			err := cmd.Run()
			if err != nil {
				fmt.Printf("Iteration %d failed: %v\n", i, err)
				return
			}
			fmt.Printf("Iteration %d finished.\n", i)
		}
	}
}
