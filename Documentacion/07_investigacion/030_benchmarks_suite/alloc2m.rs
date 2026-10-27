fn make() -> Vec<i64> { vec![1, 2, 3, 4, 5, 6, 7, 8] }
fn main() {
    let mut s = 0i64;
    for _ in 0..2000000 { let a = make(); s += a[0]; }
    println!("{}", s);
}
