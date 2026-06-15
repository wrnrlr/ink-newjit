Lets continue developing the ink-to-spirv compiler for translating
The purpose of this feauture is to be able to engineer complex graphics and compute pipelines api that can target webgpu via dawn.

It is based on a copy-and-patch compiler and the tiramisu framework. [@copy-and-patch.md](file:///Users/werner/Code/ink/doc/copy-and-patch.md) [@baghdadi_2019_tiramisu.md](file:///Users/werner/Code/ink/doc/papers/baghdadi_2019_tiramisu.md) 

Current status of the gpu module explained here:
[@gpu.md](file:///Users/werner/Code/ink/doc/gpu.md) [@gpu](file:///Users/werner/Code/ink/lib/gpu/) 

Lets first improve the 2D shader examples before moving to a more complex 3D pipelines.

We have a shadertoy like example of drawing a circle using a SDF [@circle.k](file:///Users/werner/Code/ink/test/circle.k).
The result looks ok for me.
There is something wrong in the transpiler because the monadic `sqr` keyword is not supported, when I repace `ux*ux` with `sqr ux` I don't get a circle abymore but a kind of arc.

In the compShader api can we switch around the arguments first the uniform mapping and then the lambda for teh shader. Also I want to rename the `compShader` to `FragmentShader` to clearly indicate we are just working with a fragment shader here


I want to continue working on the demos:
- `circle.k` looks ok
- `drawing.k`: Looks broken, I'm seeing a yellow rounded rect in the bottom-right corner, then a background with a slight gradient from top to bottom, and ocasional flickering.
-
