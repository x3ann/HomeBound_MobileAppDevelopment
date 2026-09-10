"use strict";

const {initializeApp} = require("firebase-admin/app");
const {
  FieldValue,
  Timestamp,
  getFirestore,
} = require("firebase-admin/firestore");
const {logger} = require("firebase-functions");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {transit_realtime: gtfsRealtime} = require("gtfs-realtime-bindings");

initializeApp();
const db = getFirestore();

const REGION = "asia-southeast1";
const TIME_ZONE = "Asia/Kuala_Lumpur";
const FEED_CATEGORIES = ["rapid-bus-kl", "rapid-bus-mrtfeeder"];
const MIN_TRAINING_SAMPLES = 1000;
const FEATURE_NAMES = [
  "precipitation_mm",
  "hour_sin",
  "hour_cos",
  "weekday_sin",
  "weekday_cos",
  "is_feeder",
];

function finiteNumber(value, fallback = 0) {
  if (value === null || value === undefined) return fallback;
  const number = typeof value === "object" && value.toNumber ?
    value.toNumber() : Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function haversineKm(a, b) {
  const radians = (degrees) => degrees * Math.PI / 180;
  const dLat = radians(b.latitude - a.latitude);
  const dLon = radians(b.longitude - a.longitude);
  const lat1 = radians(a.latitude);
  const lat2 = radians(b.latitude);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

function normalizeVehicle(entity, category, fallbackTimestamp) {
  const vehicle = entity.vehicle;
  const position = vehicle && vehicle.position;
  const trip = vehicle && vehicle.trip;
  if (!vehicle || !position || !trip) return null;
  const latitude = finiteNumber(position.latitude, NaN);
  const longitude = finiteNumber(position.longitude, NaN);
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
  const vehicleId = vehicle.vehicle && (vehicle.vehicle.id || vehicle.vehicle.label);
  if (!vehicleId && !entity.id) return null;
  return {
    vehicleId: String(vehicleId || entity.id),
    tripId: String(trip.tripId || ""),
    routeId: String(trip.routeId || ""),
    directionId: finiteNumber(trip.directionId, -1),
    sequence: finiteNumber(vehicle.currentStopSequence, 0),
    latitude,
    longitude,
    speedMps: finiteNumber(position.speed, 0),
    bearing: finiteNumber(position.bearing, 0),
    timestampSeconds: finiteNumber(vehicle.timestamp, fallbackTimestamp),
    category,
  };
}

async function fetchVehicles(category, timestampSeconds) {
  const url = new URL(
      "https://api.data.gov.my/gtfs-realtime/vehicle-position/prasarana",
  );
  url.searchParams.set("category", category);
  const response = await fetch(url, {signal: AbortSignal.timeout(15000)});
  if (!response.ok) throw new Error(`${category} feed returned ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  const feed = gtfsRealtime.FeedMessage.decode(bytes);
  return feed.entity
      .map((entity) => normalizeVehicle(entity, category, timestampSeconds))
      .filter(Boolean);
}

async function fetchWeather() {
  const url = new URL("https://api.open-meteo.com/v1/forecast");
  url.searchParams.set("latitude", "3.1390");
  url.searchParams.set("longitude", "101.6869");
  url.searchParams.set("current", "precipitation,weather_code");
  url.searchParams.set("timezone", TIME_ZONE);
  const response = await fetch(url, {signal: AbortSignal.timeout(10000)});
  if (!response.ok) throw new Error(`weather feed returned ${response.status}`);
  const body = await response.json();
  return {
    precipitationMm: finiteNumber(body.current && body.current.precipitation),
    weatherCode: finiteNumber(body.current && body.current.weather_code),
    weatherAvailable: true,
  };
}

function transitionSamples(previousVehicles, vehicles, weather) {
  const previousByVehicle = new Map(
      previousVehicles.map((vehicle) => [vehicle.vehicleId, vehicle]),
  );
  const samples = [];
  for (const current of vehicles) {
    const previous = previousByVehicle.get(current.vehicleId);
    if (!previous || !current.tripId || current.tripId !== previous.tripId) continue;
    const elapsedSeconds = current.timestampSeconds - previous.timestampSeconds;
    const sequenceDelta = current.sequence - previous.sequence;
    if (elapsedSeconds < 20 || elapsedSeconds > 900) continue;
    if (sequenceDelta < 1 || sequenceDelta > 5) continue;
    const distanceKm = haversineKm(previous, current);
    if (distanceKm > 20) continue;
    samples.push({
      category: current.category,
      routeId: current.routeId,
      tripId: current.tripId,
      directionId: current.directionId,
      fromSequence: previous.sequence,
      toSequence: current.sequence,
      sequenceDelta,
      durationSeconds: elapsedSeconds / sequenceDelta,
      distanceKm: distanceKm / sequenceDelta,
      speedKmh: current.speedMps * 3.6,
      precipitationMm: weather.precipitationMm,
      weatherCode: weather.weatherCode,
      weatherAvailable: weather.weatherAvailable,
      observedAt: Timestamp.fromMillis(current.timestampSeconds * 1000),
    });
  }
  return samples;
}

async function collectCategory(category, weather, nowSeconds) {
  const vehicles = await fetchVehicles(category, nowSeconds);
  const stateRef = db.collection("transitCollectorState").doc(category);
  const stateSnapshot = await stateRef.get();
  const previousVehicles = stateSnapshot.exists ?
    (stateSnapshot.data().vehicles || []) : [];
  const samples = transitionSamples(previousVehicles, vehicles, weather);
  const minute = Math.floor(nowSeconds / 60) * 60;
  const snapshotRef = db.collection("transitSnapshots")
      .doc(`${category}-${minute}`);
  await snapshotRef.set({
    category,
    feedTimestampSeconds: nowSeconds,
    precipitationMm: weather.precipitationMm,
    weatherCode: weather.weatherCode,
    weatherAvailable: weather.weatherAvailable,
    vehicleCount: vehicles.length,
    samples,
    observedAt: FieldValue.serverTimestamp(),
    expiresAt: Timestamp.fromMillis((minute + 14 * 86400) * 1000),
  });
  await stateRef.set({
    vehicles,
    updatedAt: FieldValue.serverTimestamp(),
  });
  return {category, vehicles: vehicles.length, samples: samples.length};
}

exports.collectTransitObservations = onSchedule({
  schedule: "every 1 minutes",
  timeZone: TIME_ZONE,
  region: REGION,
  timeoutSeconds: 55,
  memory: "512MiB",
  maxInstances: 1,
  retryCount: 0,
}, async () => {
  const nowSeconds = Math.floor(Date.now() / 1000);
  let weather = {
    precipitationMm: 0,
    weatherCode: 0,
    weatherAvailable: false,
  };
  try {
    weather = await fetchWeather();
  } catch (error) {
    logger.warn("Weather unavailable for this collection run", error);
  }
  const results = await Promise.allSettled(
      FEED_CATEGORIES.map((category) =>
        collectCategory(category, weather, nowSeconds)),
  );
  for (const result of results) {
    if (result.status === "fulfilled") logger.info("Transit feed collected", result.value);
    else logger.error("Transit feed collection failed", result.reason);
  }
});

function median(values) {
  const ordered = [...values].sort((a, b) => a - b);
  const middle = Math.floor(ordered.length / 2);
  return ordered.length % 2 ? ordered[middle] :
    (ordered[middle - 1] + ordered[middle]) / 2;
}

function timeFeatures(date) {
  const local = new Date(date.getTime() + 8 * 60 * 60 * 1000);
  const hour = local.getUTCHours() + local.getUTCMinutes() / 60;
  const weekday = local.getUTCDay();
  return {
    hourSin: Math.sin(2 * Math.PI * hour / 24),
    hourCos: Math.cos(2 * Math.PI * hour / 24),
    weekdaySin: Math.sin(2 * Math.PI * weekday / 7),
    weekdayCos: Math.cos(2 * Math.PI * weekday / 7),
  };
}

function featureVector(sample) {
  const time = timeFeatures(sample.observedAt.toDate());
  return [
    Math.max(0, Math.min(50, finiteNumber(sample.precipitationMm))),
    time.hourSin,
    time.hourCos,
    time.weekdaySin,
    time.weekdayCos,
    sample.category === "rapid-bus-mrtfeeder" ? 1 : 0,
  ];
}

function prepareRows(documents) {
  const orderedDocuments = documents
      .filter((sample) => sample.weatherAvailable === true)
      .sort((a, b) => a.observedAt.toMillis() - b.observedAt.toMillis());
  const rawSplit = Math.floor(orderedDocuments.length * 0.8);
  const groups = new Map();
  for (const sample of orderedDocuments.slice(0, rawSplit)) {
    const key = [sample.category, sample.routeId, sample.directionId,
      sample.fromSequence, sample.toSequence].join("|");
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(sample.durationSeconds);
  }
  return orderedDocuments.flatMap((sample) => {
    const key = [sample.category, sample.routeId, sample.directionId,
      sample.fromSequence, sample.toSequence].join("|");
    const durations = groups.get(key);
    if (!durations || durations.length < 5) return [];
    const typical = median(durations);
    const excessMinutes = Math.max(-3, Math.min(15,
        (sample.durationSeconds - typical) / 60));
    return [{x: featureVector(sample), y: excessMinutes,
      observedAt: sample.observedAt.toMillis()}];
  }).sort((a, b) => a.observedAt - b.observedAt);
}

function mean(values) {
  return values.reduce((total, value) => total + value, 0) / values.length;
}

function trainLinearModel(rows) {
  const split = Math.floor(rows.length * 0.8);
  const training = rows.slice(0, split);
  const validation = rows.slice(split);
  const means = FEATURE_NAMES.map((_, i) => mean(training.map((row) => row.x[i])));
  const scales = FEATURE_NAMES.map((_, i) => {
    const variance = mean(training.map((row) => (row.x[i] - means[i]) ** 2));
    return Math.max(Math.sqrt(variance), 1e-6);
  });
  const normalized = training.map((row) => ({
    x: row.x.map((value, i) => (value - means[i]) / scales[i]),
    y: row.y,
  }));
  let intercept = mean(training.map((row) => row.y));
  const weights = FEATURE_NAMES.map(() => 0);
  const learningRate = 0.025;
  const regularization = 0.002;
  for (let epoch = 0; epoch < 1200; epoch++) {
    let interceptGradient = 0;
    const gradients = weights.map(() => 0);
    for (const row of normalized) {
      const prediction = intercept + weights.reduce(
          (total, weight, i) => total + weight * row.x[i], 0);
      const error = prediction - row.y;
      interceptGradient += error;
      for (let i = 0; i < weights.length; i++) gradients[i] += error * row.x[i];
    }
    intercept -= learningRate * 2 * interceptGradient / normalized.length;
    for (let i = 0; i < weights.length; i++) {
      weights[i] -= learningRate *
        (2 * gradients[i] / normalized.length + regularization * weights[i]);
    }
  }
  const predict = (row) => Math.max(-3, Math.min(15,
    intercept + weights.reduce((total, weight, i) =>
      total + weight * ((row.x[i] - means[i]) / scales[i]), 0)));
  const validationMae = mean(validation.map((row) => Math.abs(predict(row) - row.y)));
  const baseline = mean(training.map((row) => row.y));
  const baselineMae = mean(validation.map((row) => Math.abs(baseline - row.y)));
  const validationRmse = Math.sqrt(mean(validation.map((row) =>
    (predict(row) - row.y) ** 2)));
  return {intercept, weights, means, scales, validationMae,
    validationRmse, baselineMae, trainingCount: training.length,
    validationCount: validation.length};
}

exports.trainTransitDelayModel = onSchedule({
  schedule: "15 4 * * *",
  timeZone: TIME_ZONE,
  region: REGION,
  timeoutSeconds: 540,
  memory: "1GiB",
  maxInstances: 1,
  retryCount: 0,
}, async () => {
  const snapshot = await db.collection("transitSnapshots")
      .orderBy("observedAt", "desc").limit(20000).get();
  const observations = snapshot.docs.flatMap((document) => {
    const data = document.data();
    return Array.isArray(data.samples) ? data.samples : [];
  });
  const rows = prepareRows(observations);
  const statusRef = db.collection("delayModelTraining").doc("status");
  if (rows.length < MIN_TRAINING_SAMPLES) {
    await statusRef.set({
      status: "collecting",
      usableSamples: rows.length,
      minimumSamples: MIN_TRAINING_SAMPLES,
      checkedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    logger.info("Not enough labelled observations to train", {samples: rows.length});
    return;
  }

  const model = trainLinearModel(rows);
  const version = `bus-delay-${Date.now()}`;
  const candidate = {
    schemaVersion: 1,
    version,
    scope: "bus",
    categories: FEED_CATEGORIES,
    featureNames: FEATURE_NAMES,
    intercept: model.intercept,
    weights: model.weights,
    means: model.means,
    scales: model.scales,
    minimumMinutes: -3,
    maximumMinutes: 15,
    sampleCount: rows.length,
    trainingCount: model.trainingCount,
    validationCount: model.validationCount,
    validationMae: model.validationMae,
    validationRmse: model.validationRmse,
    baselineMae: model.baselineMae,
    trainedAt: FieldValue.serverTimestamp(),
  };
  await db.collection("delayModelCandidates").doc(version).set(candidate);
  const improvesBaseline = model.validationMae < model.baselineMae;
  if (improvesBaseline) {
    await db.collection("delayModels").doc("current").set({
      ...candidate,
      status: "active",
    });
  }
  await statusRef.set({
    status: improvesBaseline ? "promoted" : "rejected",
    version,
    usableSamples: rows.length,
    validationMae: model.validationMae,
    baselineMae: model.baselineMae,
    checkedAt: FieldValue.serverTimestamp(),
  }, {merge: true});
  logger.info("Transit model training completed", {
    version, promoted: improvesBaseline,
    validationMae: model.validationMae, baselineMae: model.baselineMae,
  });
});

exports.cleanupTransitTrainingData = onSchedule({
  schedule: "45 4 * * *",
  timeZone: TIME_ZONE,
  region: REGION,
  timeoutSeconds: 300,
  memory: "256MiB",
  maxInstances: 1,
}, async () => {
  const cutoff = Timestamp.now();
  for (const collectionName of ["transitSnapshots"]) {
    let removed = 0;
    while (true) {
      const expired = await db.collection(collectionName)
          .where("expiresAt", "<", cutoff).limit(400).get();
      if (expired.empty) break;
      const batch = db.batch();
      for (const document of expired.docs) batch.delete(document.ref);
      await batch.commit();
      removed += expired.size;
    }
    logger.info("Expired training data removed", {collectionName, removed});
  }
});

exports._test = {
  featureVector,
  fetchVehicles,
  haversineKm,
  prepareRows,
  timeFeatures,
  trainLinearModel,
  transitionSamples,
};
