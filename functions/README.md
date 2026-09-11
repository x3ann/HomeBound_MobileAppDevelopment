# Transit delay model backend

This backend collects genuine Rapid KL bus vehicle observations and trains a
small regression model. It never creates synthetic production labels.

## Data flow

1. `collectTransitObservations` runs every minute and reads the official
   GTFS-Realtime vehicle-position feeds for Rapid KL and MRT feeder buses.
2. A training sample is created when the same vehicle and trip show credible
   GPS movement across consecutive observations. Stationary noise and
   physically impossible jumps are discarded. Samples from one feed minute
   are stored together to keep Firestore operations predictable.
3. `trainTransitDelayModel` runs daily. It normalizes GPS travel speed against
   the typical speed for the same route and direction. The label is excess
   minutes on a representative ten-minute bus segment. It then uses a
   chronological 80/20 split to train and validate a linear regression.
4. A candidate replaces `delayModels/current` only when it has at least 1,000
   usable samples and beats the constant baseline on unseen observations.
5. The Flutter app reads only the promoted model. Until one exists, it uses its
   clearly-labelled schedule and weather fallback.

The public national feed does not currently provide stable realtime rail data,
so this model must not be presented as an MRT/LRT delay model.

At two feeds per minute, the collector performs about 2,880 reads and 5,760
writes per day before model-training operations. Fourteen-day retention and a
20,000-document training cap keep the expected workload within Firestore's
standard daily free quota, but billing alerts must still be configured.

## Deploy

The project must be on the Blaze plan because scheduled functions use Cloud
Scheduler. Install dependencies and test before deployment:

```powershell
cd functions
npm install
npm test
cd ..
npx firebase-tools login
npx firebase-tools deploy --only functions,firestore:rules
```

After deployment, check `delayModelTraining/status` in Firestore. The first
validated model is promoted automatically only after sufficient real data has
been collected.
