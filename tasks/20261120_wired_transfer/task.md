goal: implement wired transfer support

when no wifi, i need another way to transfer data. i want wired transfer support.

for the profile, name it wired transfer and for new users (new devices), let the path default to the downloads folder (standard default path that many applications are using) of the device (most likely a laptop/desktop) that the iphone is being plugged into. i'm not sure if there's a variable that resolves to the correct path for all devices so that you can code the logic for all devices in the code, or a one-time manual setup is needed on every new device (new user) and default has to be an empty string or what. the path is changeable, of course, regardless of whether the default path logic can work.

the data should physically exist under `/pub5/data/ivision-indoor/`, and a symlink `/pub0/data/ivision-indoor/` should exist and point to `/pub5/data/ivision-indoor/`. no where shall reference pub5. everywhere references pub0.
