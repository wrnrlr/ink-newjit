import random
import time

directions = [(0, 1), (0, -1), (1, 0), (-1, 0)]

def bounds(x):
    return 0 < x[0] < 9 and 0 < x[1] < 9

def wander(x):
    d = random.choice(directions)
    return (x[0] + d[0], x[1] + d[1])

def steps():
    pos = (5, 5)
    count = 0
    while bounds(pos):
        pos = wander(pos)
        count += 1
    return count

start = time.perf_counter()
total = sum(steps() for _ in range(100_000))
result = total / 100_000
elapsed = (time.perf_counter() - start) * 1000

print(f"{result:.4f}")
print(f"{elapsed:.0f}ms")
