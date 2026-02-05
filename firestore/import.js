console.log("🚀 Import script started");

const admin = require("firebase-admin");
const data = require("./kathmandu_transport_firestore.json");
const serviceAccount = require("./serviceAccountKey.json");

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

async function importData() {
  console.log("📦 Collections:", Object.keys(data));

  for (const collectionName of Object.keys(data)) {
    for (const docId of Object.keys(data[collectionName])) {
      console.log(`➡️ ${collectionName}/${docId}`);
      await db
        .collection(collectionName)
        .doc(docId)
        .set(data[collectionName][docId]);
    }
  }

  console.log("✅ Firestore import complete");
}

importData()
  .then(() => process.exit(0))
  .catch(err => {
    console.error("❌ Error:", err);
    process.exit(1);
  });
