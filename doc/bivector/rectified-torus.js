Algebra(3,0,1,()=>{
  
  const [r1,r2,r3] = [.8, .4, .1];
  const [A,B] = [4,3];  
  
  // Handy shortcuts and mnemonize function
  
  const {E, PI} = Math;
  const makeFast = f => { var c={}; return t=>c[t]??(c[t]=f(t))};
  
  // Lets get some circles
  
  var c1 = t => E**(t * PI * 1e13) * E**(r1 * 0.5e01),
      c2 = t => E**(t * PI * 1e12) * E**(r2 * 0.5e01);
      
  // Derivative of circle
      
  var dc1 = t => PI * 1e13 * c1(t),    
      dc2 = t => PI * 1e12 * c2(t);   
  
  // Torus
  
  var t1 = (s,t) => c1(s) * c2(t);
  
  // Knot and its derivative
  // f(g(x))' = f'(g(x)) g'(x)
  
  var k1 = makeFast(t => c1(t*A) * c2(t*B));
  var dk1 = makeFast(t => A*dc1(t*A)*c2(t*B) + B*c1(t*A)*dc2(t*B));
  
  // Knot on origin and its derivative
  // (fgh)' = f'gh + fg'h + fgh'
  
  var k1o = t => k1(t) * 1e123 * ~k1(t);
  var dk1o = t => dk1(t) * 1e123 * ~k1(t) + k1(t) * 1e123 * ~dk1(t) 

  //  rectified knot
  var k1r = makeFast(t => {
    // Our current position on the knot
    var R = k1(t);
    // The (dual to) the z-axis which we want to align to the curve
    var from = 1e3;
    // The (dual to) the tangent direction on the curve
    var to = (!(~R >>> dk1o(t))).Normalized;
    // Return the updated rotor.
    return R *                           // Original rotor on knot
           (1 + to/from).Normalized *    // Pre-rotate so the z-axis aligns the tangent
           E**((t*B - 0.125 )*PI*1e12);  // Undo the torsion along the knot
  })
  
  // Thick Knot
  var c3 = makeFast(t => E**(t * PI * 1e12) * E**(r3 * 0.5e01));
  var kc = (s,t) => k1r(s) * c3(t);
  kc.dx = 2048;
  kc.dy = 5;
  
  // Render stuff
  return this.graph(()=>{
    var t = performance.now() / 20000;
    return [
       //0xff9900, t1,
       0x009977, kc,
       0, k1o(t),
      ...k1r(t) >>> [
         0xff0000, [!(1e0-0.4e1), !(1e0+0.0e1)],
         0x00ff00, [!(1e0-0.4e2), !(1e0+0.0e2)],
         0x0000ff, [!(1e0-0.4e3), !(1e0+0.4e3)],
      ]
    ]
  },{
    gl: 1,
    lineWidth : 4,
    animate : 1,
    p:-0.3,
  })
  
  
})
