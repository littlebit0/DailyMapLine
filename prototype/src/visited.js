import buffer from '@turf/buffer';

// Invert the buffered route, preserving every inner ring (unvisited islands).
export function createFogMask(coordinates) {
  const world = [[-180, -84], [180, -84], [180, 84], [-180, 84], [-180, -84]];
  const visited = coordinates ? buffer({
    type: 'Feature', properties: {},
    geometry: { type: 'LineString', coordinates },
  }, 50, { units: 'meters', steps: 12 }) : null;
  const polygons = !visited ? [] : visited.geometry.type === 'Polygon'
    ? [visited.geometry.coordinates] : visited.geometry.coordinates;
  const polygon = rings => ({ type: 'Feature', properties: {}, geometry: { type: 'Polygon', coordinates: rings } });
  return {
    type: 'FeatureCollection',
    features: [
      polygon([world, ...polygons.map(rings => rings[0])]),
      ...polygons.flatMap(rings => rings.slice(1).map(ring => polygon([ring]))),
    ],
  };
}
