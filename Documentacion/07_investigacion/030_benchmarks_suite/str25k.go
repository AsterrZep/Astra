package main

import "fmt"

func main() {
	s := ""
	for i := 0; i < 25000; i++ { s = s + "x" }
	fmt.Println(s)
}
