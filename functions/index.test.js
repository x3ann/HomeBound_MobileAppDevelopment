"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  haversineKm,
  trainLinearModel,
  transitionSamples,
} = require("./index")._test;

test("creates a real segment observation when a vehicle advances", () => {
  const previous = [{
    vehicleId: "bus-1", tripId: "trip-1", routeId: "route-1",
    directionId: 0, sequence: 4, latitude: 3.14, longitude: 101.68,
    speedMps: 5, timestampSeconds: 1000, category: "rapid-bus-kl",
  }];
  const current = [{...previous[0], sequence: 5, longitude: 101.69,
    timestampSeconds: 1120}];
  const samples = transitionSamples(previous, current,
      {precipitationMm: 2, weatherCode: 61, weatherAvailable: true});
  assert.equal(samples.length, 1);
  assert.equal(samples[0].durationSeconds, 120);
  assert.equal(samples[0].precipitationMm, 2);
  assert.ok(samples[0].distanceKm > 0);
});

test("rejects GPS jumps and non-progressing vehicles", () => {
  const base = {vehicleId: "bus-1", tripId: "trip-1", routeId: "route-1",
    directionId: 0, sequence: 4, latitude: 3.14, longitude: 101.68,
    speedMps: 5, timestampSeconds: 1000, category: "rapid-bus-kl"};
  assert.equal(transitionSamples([base], [{...base, timestampSeconds: 1060}],
      {precipitationMm: 0, weatherCode: 0}).length, 0);
  assert.ok(haversineKm(base, {...base, latitude: 4.14}) > 20);
});

test("linear trainer learns a weather-related delay signal", () => {
  const rows = Array.from({length: 1200}, (_, index) => {
    const rain = (index % 20) / 2;
    return {
      x: [rain, Math.sin(index), Math.cos(index), 0, 1, index % 2],
      y: rain * 0.4,
      observedAt: index,
    };
  });
  const model = trainLinearModel(rows);
  assert.ok(model.validationMae < model.baselineMae);
  assert.ok(model.weights[0] > 0);
});
