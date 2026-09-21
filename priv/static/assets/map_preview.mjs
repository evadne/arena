// Display-only geometry from the backend. No mission state or client map generation.
export function previewMesh(map) {
  const size = map.tile_size;
  const floor = map.floor_tiles.map(([x, y]) => [x * size, y * size]);
  const corners = map.walls.flatMap(w => [[w.x, w.y], [w.x + w.w, w.y + w.h]]);
  const xs = corners.map(p => p[0]), ys = corners.map(p => p[1]);
  const centre = [(Math.min(...xs) + Math.max(...xs)) / 2, (Math.min(...ys) + Math.max(...ys)) / 2];
  const diameter = Math.hypot(Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys));
  const rect = (x, y, w, h, z) => [[x,y,z],[x+w,y,z],[x+w,y+h,z],[x,y+h,z]];
  const floors = floor.map(([x,y]) => rect(x,y,size,size,0));
  const faces = [];
  const occupied = new Set(map.walls.map(w => `${w.x},${w.y}`));
  for (const {x,y,w,h} of map.walls) {
    const bottom = rect(x,y,w,h,0), top = rect(x,y,w,h,30);
    faces.push({points:top,fill:"#698467",edge:"#94ae7d80"});
    const neighbours = [[x,y-h],[x+w,y],[x,y+h],[x-w,y]];
    for (let i=0;i<4;i++) {
      if (occupied.has(neighbours[i].join(','))) continue;
      const next=(i+1)%4;
      faces.push({points:[bottom[i],bottom[next],top[next],top[i]],
        fill:i%2 ? "#314d3c" : "#415f47",edge:"#72936845"});
    }
  }
  return {centre,diameter,floors,faces};
}

export function drawPreview(ctx, mesh, width, height, elapsed, reducedMotion) {
  if (!mesh) return;
  const angle = -0.48 + (reducedMotion ? 0 : elapsed * Math.PI * 2 / 480000);
  const cos=Math.cos(angle), sin=Math.sin(angle), tilt=0.98;
  const scale=Math.min(width * (width<760 ? 1.15 : 0.66),height*0.94) / mesh.diameter;
  const centreX=width*(width<760 ? 0.67 : 0.70), centreY=height*0.53;
  const distance=mesh.diameter*2.8;
  const project=([x,y,z]) => {
    x-=mesh.centre[0]; y-=mesh.centre[1];
    const rx=x*cos-y*sin, ry=x*sin+y*cos;
    const depth=ry*Math.sin(tilt)+z*Math.cos(tilt);
    const perspective=distance/(distance-depth);
    return [centreX+rx*scale*perspective,centreY+(ry*Math.cos(tilt)-z*Math.sin(tilt))*scale*perspective,depth];
  };
  const polygon=(points,fill,edge) => {
    ctx.beginPath();
    points.forEach(([x,y],i) => i ? ctx.lineTo(x,y) : ctx.moveTo(x,y));
    ctx.closePath(); ctx.fillStyle=fill; ctx.fill();
    ctx.strokeStyle=edge; ctx.lineWidth=0.65; ctx.stroke();
  };
  for(const floor of mesh.floors) polygon(floor.map(project),"#193426","#6b8c5b35");
  const faces=mesh.faces.map(face => ({...face,points:face.points.map(project)}));
  faces.sort((a,b) => a.points.reduce((n,p)=>n+p[2],0)/a.points.length-b.points.reduce((n,p)=>n+p[2],0)/b.points.length);
  for(const face of faces) polygon(face.points,face.fill,face.edge);
}
