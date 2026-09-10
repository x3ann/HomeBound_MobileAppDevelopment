# HomeBound manual test run

Run this checklist on a physical Android phone when possible. Use mobile data once and Wi-Fi once. Record the phone time, location, selected stop, displayed source badge, and a screenshot for every failure.

## Before starting

- Enable precise location, mobile data/Wi-Fi, and phone calling permission when requested.
- Set date, time, and time zone to automatic. The expected zone in Malaysia is GMT+8.
- Start the app with `flutter run`, then press `R` in the terminal for a hot restart.
- Confirm there is no red error screen and no yellow/black overflow stripe in portrait or landscape.
- Do not treat a scheduled time as a live arrival. The screen must explicitly say `live` or `scheduled`.

## 1. Sign in and registration

1. Open the app while signed out.
2. Try an invalid email and a short password. Expected: clear validation; no crash.
3. Register a test account, then sign out and sign in again. Expected: successful navigation to Home.
4. Turn off the network and attempt sign-in. Expected: an understandable error and a usable retry.

## 2. Home

1. Allow precise location. Expected: the nearest card and nearby list reorder for the phone's real position; the location is not a fixed demo coordinate.
2. Compare the nearest stop distance with Google Maps or another map. Expected: broadly similar straight-line distance; walking distance may be longer.
3. Tap `Refresh my current location` after moving at least 100 m or changing the emulator location. Expected: location and stop order update.
4. Check the source text on the nearest bus. Expected: `Estimated from the latest live bus position` only when a fresh vehicle match exists; otherwise `Official scheduled departure · live bus unavailable`.
5. Compare a scheduled departure and last service with the operator timetable for the same route, stop, weekday, and direction. Expected: the same published clock time. Allow for a feed update delay, but never a negative countdown.
6. Wait for a countdown to reach zero. Expected: it refreshes to the next departure or changes to `No more today`/`Out of service`; it must not continue below zero.
7. Tap a nearby bus route. Expected: Map opens focused on that route/nearby stops and the route label matches the tapped row.
8. Open `View full service timetable`; test Bus, LRT, MRT, Monorail, BRT, and each available line. Expected: filters change the list and every row identifies its transport type, line, next scheduled departure, and last scheduled service.
9. Deny location permission and repeat. Expected: a permission explanation and retry path, not a fixed location presented as yours.

## 3. Map

1. Open Map. Expected: blue user marker at the current location, stops within the chosen 1 km/2 km radius, and fresh source/update labels.
2. Test All, Bus, LRT, MRT, Monorail, and BRT filters, then each line filter. Expected: markers/list/lines change together; no marker from an excluded mode remains.
3. Search for a station name and a bus route number. Expected: matching suggestions/results and no unrelated fixed result.
4. Press `+`, `−`, and current-location controls. Expected: zoom changes one level at a time and location recentres accurately.
5. Tap a rail station and a bus stop. Expected: full name, mode, route/line, distance, next departure state, last service, and coordinates are consistent with the selected marker.
6. Request directions to the selected stop. Expected: the line follows walkable roads when routing is available; if unavailable, the app clearly labels the fallback and does not claim turn-by-turn road guidance.
7. Move/change emulator location. Expected: user marker updates within about 5 seconds; stop distances/order refresh after meaningful movement.
8. Change the phone clock by at least 10 minutes, return to the app, then restore automatic time. Expected: countdowns and the update timestamp recalculate without restarting.

## 4. Route planner

1. Use current location as origin and type `MRT Kepong Baru` slowly. Expected: suggestions narrow as text is entered and a suggestion can be selected.
2. Repeat with a bus stop/route query. Expected: bus suggestions are available, not rail only.
3. Save Home, Work, and a custom label. Expected: the custom wording is preserved, selectable, editable, and does not overwrite another saved place.
4. Plan from Bandar Utama to MRT Kepong Baru. Expected: at least the fastest valid option plus a different-mode bus alternative when an official feasible bus journey exists. An unavailable alternative must not be invented.
5. Check each route card: departure, arrival, total minutes, transfers, lines/routes, walking time/distance, stop count, and direction. Expected: total minutes equals approximately arrival minus journey start, rounded up; arrival is after departure.
6. Open every card. Expected: detailed boarding, transfer, alighting, exit, and walking instructions; checkpoints are in travel order and use the same stop/line names as the summary.
7. Tap `Go · start journey`. Expected: Map opens in journey mode, frames the journey, shows A/B and numbered checkpoints, and displays scheduled progress.
8. Tap focus, current-location/follow, and exit. Expected: focus shows the entire route; follow recentres on movement; exit returns to the normal map controls.
9. Try an impossible pair and a blank destination. Expected: a clear no-route/validation message, no fabricated itinerary, and no crash.

## 5. Delay risk

1. Select origin and destination for a direct rail trip, a bus trip, and a trip requiring a transfer. Expected: route/mode and total estimated travel time change with the selection.
2. Confirm the screen shows when the estimate was calculated, confidence, factors, and source. Expected: the same input at the same time gives a stable value; it is not always one fixed percentage.
3. If the source says a validated trained bus model was used, confirm Firestore has `delayModels/current` with validation/sample fields. If not, expected: the screen describes the schedule/weather fallback and does not claim a trained result.
4. Tap `Go now`. Expected: Planner opens with origin/destination filled and shows detailed routes.
5. Disable network and retry. Expected: confidence/source downgrade or an error; no live-data claim.

## 6. SOS

1. Confirm call choice can switch between 999 and an emergency contact.
2. Add/edit an emergency contact. Expected: the displayed target updates and persists after reopening.
3. Long-press SOS. Cancel before placing a real call. Expected: confirmation/progress is visible and the phone dial screen opens with the selected number.
4. Deny phone/location permission. Expected: clear permission guidance; the page remains usable.
5. Confirm call action is above location status and location refreshes about every 5 seconds while safety tracking is active.

## 7. Profile and navigation

1. Edit profile details, close, and reopen. Expected: saved values persist.
2. Test Home, Map, Plan, Predict, and SOS navigation repeatedly. Expected: no duplicate screens, stale selection, or crash.
3. Rotate to landscape. Expected: navigation moves to the left rail and content remains scrollable with no overflow.
4. Rotate back to portrait. Expected: navigation returns to the bottom and state is retained.

## 8. Reliability and acceptance

1. Background the app for 2 minutes, resume, and refresh every data page. Expected: current clock/location/data refresh; no old countdown continues blindly.
2. Switch network off, open all pages, then restore it. Expected: cached schedule is labelled as cached, live values are not claimed, and retry recovers.
3. Leave Home and Map open across the 4:00 AM service-day boundary if practical. Expected: bus and rail calendars reload for the new service day.
4. Check terminal output throughout. Pass only with no uncaught exception, assertion, repeated request loop, or render overflow.
5. Run `dart analyze` and `flutter test`. Both must finish successfully before merging.

## Accuracy limits to explain in the presentation

- Rail and bus timetables are official published GTFS schedules, not a guarantee of actual arrival.
- Live bus ETA is an app estimate from a fresh vehicle position matched to its scheduled trip. It is not traffic-aware turn-by-turn prediction.
- Rail has no equivalent live vehicle/arrival feed in the current integration, so rail countdowns are scheduled.
- Coverage includes the lines and routes present in the selected Rapid KL/Rapid Rail feeds. It does not mean every public transport operator in Malaysia.
- The official API warns that roughly 2% of Rapid KL bus trips are temporarily absent from its published stop-time data, so the app cannot display those missing trips.
- Journey map progress is time-based scheduled progress. It is not proof that the rider boarded a vehicle; numbered checkpoints help the user confirm the real journey.
