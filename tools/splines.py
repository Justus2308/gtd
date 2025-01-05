import numpy as np
import matplotlib.pyplot as plt

def catmull_rom_point(p0: tuple, p1: tuple, p2: tuple, p3: tuple, t: float, alpha: float):
    def tj(ti: float, pi: tuple, pj: tuple) -> float:
        xi, yi = pi
        xj, yj = pj
        dx, dy = xj - xi, yj - yi
        l = (dx ** 2 + dy ** 2) ** 0.5
        return ti + l ** alpha

    t0: float = 0.0
    t1: float = tj(t0, p0, p1)
    t2: float = tj(t1, p1, p2)
    t3: float = tj(t2, p2, p3)

    a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
    a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
    a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
    b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
    b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
    p = (t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2

    return p

def transform_control_points(p):
    assert len(p) == 4
    a = -1.0
    c0 = a*2.0*p[0] + p[1]
    c1 = p[1]
    c2 = p[2]
    c3 = a*p[0] + p[1] + p[2] + p[3]
    # c0 = 0.5*p[1]
    # c1 = 1.0*p[1]
    # c2 = 0.5*p[1]
    # c3 = -3.0/2.0*p[1]
    return (c0, c1, c2, c3)

def catmull_rom(p_x, p_y, res, alpha):
    assert len(p_x) == len(p_y) == 4

    x = [catmull_rom_point(p_x[0], p_x[1], p_x[2], p_x[3], t, alpha) for t in np.linspace(0., 1., res, endpoint=False)]
    y = [catmull_rom_point(p_x[0], p_x[1], p_x[2], p_x[3], t, alpha) for t in np.linspace(0., 1., res, endpoint=False)]

    return (x, y)


a_uniform = 0.0
a_centripetal = 0.5

if __name__ == '__main__':
    res = 50

    p_x = np.arange(0,4, dtype='float32')
    p_y = np.zeros_like(p_x)
    for i in range(len(p_x)):
        p_y[i] = np.random.rand()*3. - 1.5

    cx_intpol, cy_intpol = catmull_rom(p_x, p_y, res, a_centripetal)

    q_x, q_y = p_x, p_y # transform_control_points(p_x), transform_control_points(p_y)
    ux_intpol, uy_intpol = catmull_rom(p_x, p_y, res, a_uniform)

    plt.figure()

    plt.scatter(p_x, p_y)
    for i, (x, y) in enumerate(zip(p_x, p_y)):
        plt.text(x, y, f"({x:.2f}, {y:.2f})", fontsize=9, ha="left", color="blue")

    plt.scatter(q_x, q_y)
    for i, (x, y) in enumerate(zip(q_x, q_y)):
        plt.text(x, y, f"({x:.2f}, {y:.2f})", fontsize=9, ha="right", color="red")

    plt.plot(cx_intpol, cy_intpol, color="blue")
    plt.plot(ux_intpol, uy_intpol, color="red", linestyle='dashed')

    plt.axis("equal")
    plt.grid(True)

    plt.show()
