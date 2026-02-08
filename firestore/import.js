// import.js
const admin = require("firebase-admin");
const fs = require("fs");
const path = require("path");

// ------------------
// 1️⃣ Load service account
// ------------------
let serviceAccountPath = path.join(__dirname, "serviceAccountKey.json");

if (!fs.existsSync(serviceAccountPath)) {
  console.error("❌ Service account file not found:", serviceAccountPath);
  process.exit(1);
}

const serviceAccount = require(serviceAccountPath);

// Initialize Firebase Admin
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const db = admin.firestore();

// ------------------
// 2️⃣ Load JSON data
// ------------------
const dataPath = path.join(__dirname, "kathmandu_transport_firestore.json");

if (!fs.existsSync(dataPath)) {
  console.error("❌ JSON data file not found:", dataPath);
  process.exit(1);
}

const rawData = fs.readFileSync(dataPath);
const data = JSON.parse(rawData);

// ------------------
// 3️⃣ Import function
// ------------------
async function importData() {
  try {
    // ---- Import Stops ----
    const stops = data.stops;
    console.log(`➡️ Importing ${Object.keys(stops).length} stops...`);

    for (const stopId in stops) {
      const stop = stops[stopId];

      // Remove undefined fields
      Object.keys(stop).forEach((key) => {
        if (stop[key] === undefined) delete stop[key];
      });

      await db.collection("stops").doc(stopId).set(stop);
      console.log(`✅ Imported stop: ${stopId}`);
    }

    // ---- Import Routes ----
    const routes = data.routes;
    console.log(`➡️ Importing ${Object.keys(routes).length} routes...`);

    for (const routeKey in routes) {
      const route = routes[routeKey];

      // Remove undefined fields
      Object.keys(route).forEach((key) => {
        if (route[key] === undefined) delete route[key];
      });

      // Use route.id as document ID
      await db.collection("routes").doc(route.id).set(route);
      console.log(`✅ Imported route: ${route.name}`);
    }

    // ---- Print all Stops ----
    console.log("\n📄 All stops in Firestore:");
    const stopsSnapshot = await db.collection("stops").get();
    stopsSnapshot.forEach((doc) => console.log(doc.id, "=>", doc.data()));

    // ---- Print all Routes ----
    console.log("\n📄 All routes in Firestore:");
    const routesSnapshot = await db.collection("routes").get();
    routesSnapshot.forEach((doc) => console.log(doc.id, "=>", doc.data()));

    console.log("\n🎉 Import complete!");
    process.exit(0);
  } catch (error) {
    console.error("❌ Import failed:", error);
    process.exit(1);
  }
}

// Run import
importData();
