goal: improve user experience

## Table of Contents <!-- omit in toc -->

- [1. Guidelines](#1-guidelines)
  - [1.1. Problem 1: Arbitrarily Long Recordings](#11-problem-1-arbitrarily-long-recordings)
  - [1.2. Problem 2: Recording Naming UI](#12-problem-2-recording-naming-ui)
  - [1.3. Problem 3: Multi-User](#13-problem-3-multi-user)
- [2. Definition of Done](#2-definition-of-done)

----------

## 1. Guidelines

The builds this task produces are enumerated from 5.0. Every solved problem is a subversion (doesn't have to happen in order). e.g., once you solve problem 2, then that's 5.0, and once you solve problem 1 afterwards, that's 5.1.

### 1.1. Problem 1: Arbitrarily Long Recordings

Long scans may cause the device out of space (study the logs to see the details of the issue).

Solutions (all items to be implemented):
1. record both color and depth streams at 15fps, hard coded.
2. implement lossless compression (encode on the app and decode in the data pipeline).
3. lower front camera color frames resolution from 4032x3024 to 1920x1440.
4. implement immediate upload to server and delete a frame on phone after it arrives at server.
   1. an option to have the data stay on phone should still be supported (see problem 3).
   2. the server:path configs should still show the list of scans (fetched from the server), rather than being empty.
   3. the delete icon (button) should only exist for those items under the "this phone" config, not the server:path configs.

### 1.2. Problem 2: Recording Naming UI

Once the record button is clicked, it then prompts for a name before recording, which is correct. There are two sub-problems
1. once clicked, there's no way to cancel without proceeding, unless i close the app and reopen. there needs to be a cancel option in addition to "later" and "start".
2. even with nothing written, users can still click start, and the effect is the same as later, which is bad design. when nothing is input, the start button should be disabled.

### 1.3. Problem 3: Multi-User

1. The server and location on server where the recordings are uploaded should be different for each user.
2. Each user should be able to save multiple configs, where each config is a (server, data root) pair.
3. For now, no authentication is required. You can think of users simply as folders of config grouping.
4. For now, i need two users, `daniel` and `dmytro.klepachevskyi`.
   1. for `daniel`, make three configs:
      1. the data stays on the iphone.
      2. citrus server and the `outputs` dir of this task. this config is used for any testing recording when working on this task.
      3. aloe server and `/pub0/data/officehours-v2/` this data root dir path.
   2. for `dmytro.klepachevskyi`, make three configs:
      1. the data stays on the iphone.
      2. aloe server and `/pub0/data/officehours-v2/` this data root dir path.
      3. aloe server and `/pub0/dmytro.klepachevskyi/rgbd-scanner-test-recordings/` this data root dir path.
5. when the app is opened, choose a user/config and then go to the scanner page. at the scanner page, there should be a button to go back to the user/config selection page.

## 2. Definition of Done

All problems listed above solved.
