goal: get the bare minimal version working

## Table of Contents <!-- omit in toc -->

- [1. Guidelines](#1-guidelines)
  - [1.1. App Spec](#11-app-spec)
  - [1.2. References](#12-references)
- [2. Definition of Done](#2-definition-of-done)

----------

## 1. Guidelines

### 1.1. App Spec

The app should be able to collect RGB-D video, with timestamp (for each of color stream and depth stream if they are separate, or the timestamp of synced color and depth frames).

Once start recording is clicked there should be a prompt asking for a name for the recording. The user has the option to decline (defer) the naming.

Upon recording finish, if the recording wasn't named before it started, prompt again for name.

After the recording is named or the naming is declined (by default name it by date and time), the data should be able to be sent as a single-file package to this machine, and put under this folder.

### 1.2. References

There's one session in which I was setting up iOS development with ubuntu remote machine and windows local machine. Identify that and study the transcripts.

There's one session in which I was discussing how an iOS app should be created so that the front and rear cameras collect actual sensor depth, rather than smoothened/filtered, and in highest possible precision. Identify that and study the transcripts.

## 2. Definition of Done

The app works as specified.
