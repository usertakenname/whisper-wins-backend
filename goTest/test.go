package main

import (
	"fmt"
	"os"
	"os/exec"
)

func main() {
	for num_bidder := 1; num_bidder <= 7; num_bidder++ {

		for i := 1; i <= 3; i++ {
			fmt.Printf("Starting iteration %d...\n", i)
			cmd := exec.Command("go", "run", "main.go", fmt.Sprint(num_bidder))
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			err := cmd.Run()
			if err != nil {
				fmt.Printf("Iteration %d failed: %v\n", i, err)
				break
			}
			fmt.Printf("Iteration %d finished.\n", i)
		}
	}
}
