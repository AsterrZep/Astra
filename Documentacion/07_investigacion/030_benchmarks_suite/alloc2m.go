package main

import "fmt"

func make8() []int64 { return []int64{1, 2, 3, 4, 5, 6, 7, 8} }

func main() {
	var s int64
	for i := 0; i < 2000000; i++ {
		a := make8()
		s += a[0]
	}
	fmt.Println(s)
}
