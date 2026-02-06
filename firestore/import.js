const admin = require("firebase-admin");
const fs = require("fs");
const path = require("path");

// ------------------
// Initialize Firebase Admin SDK
// ------------------
const serviceAccountPath = path.join(__dirname, "serviceAccountKey.json");

admin.initializeApp({
  credential: admin.credential.cert(serviceAccountPath),
});

const db = admin.firestore();

// ------------------
// Load JSON file
// ------------------
const jsonFilePath = path.join(__dirname, "kathmandu_transport_firestore.json");
const data = JSON.parse(fs.readFileSync(jsonFilePath, "utf-8"));

async function importStops() {
  const stops = data.stops || {};
  console.log(`➡️ Importing ${Object.keys(stops).length} stops...`);

  for (const key of Object.keys(stops)) {
    const stop = stops[key];
    await db.collection("stops").doc(key).set({
      name: stop.name,
      lat: stop.lat,
      lng: stop.lng,
    });
    console.log(`✅ stops/${key}`);
  }
}

async function importRoutes() {
  const routes = data.routes || {};
  console.log(`➡️ Importing ${Object.keys(routes).length} routes...`);

  for (const key of Object.keys(routes)) {
    const route = routes[key];
    await db.collection("routes").doc(key).set({
      name: route.name,
      vehicle: route.vehicle,
      stopIds: route.stopIds,
    });
    console.log(`✅ routes/${key}`);
  }
}

async function main() {
  try {
    console.log("🚀 Import script started");

    await importStops();
    await importRoutes();

    console.log("🎉 Import completed!");
    process.exit(0);
  } catch (err) {
    console.error("❌ Import failed:", err);
    process.exit(1);
  }
}

main();
