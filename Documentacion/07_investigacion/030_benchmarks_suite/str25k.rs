fn main() {
    let mut s = String::new();
    for _ in 0..25000 { s = s + "x"; }
    println!("{}", s);
}
