# AutoLoom tasks

- Stored with SwiftData on this iPhone (`TaskItem`: title, notes, created, due date and whether it has a time, completed and when, priority, source, linked memory, linked note, notification id).
- By voice: "görev oluştur: …", "yarına görev oluştur", "bunun için yarına görev oluştur" (after a note: the task links to it), "todo'ya ekle", "bunu yapmam lazım"; questions about the day ("bugün ne yapmam lazım") stay the day plan.
- A task with a time schedules a local notification.
- A task made while a dealer vehicle is active is linked to it.
- The same task within 60 seconds is stored once.
- "Son yaptığını geri al" removes the task just made, or reopens the task just completed by voice.
- Repeating tasks ("her gün 9'da …", "her pazartesi …", "her ayın 15'inde …", or the Repeat picker): completing one adds the next, never in the past and counted from the first date, with an alert when the completed one had one; undoing the completion takes the added one back. The repeat is kept in the app's settings beside the SwiftData store (no schema migration).
- Tasks tab: today, upcoming, done; Tomorrow / Reschedule; complete by voice ("… görevini tamamla").
- App Intent: "New AutoLoom task" (title, optional due date) without opening the app.
- Tasks are the app's own; Apple Reminders stay separate (the day plan reads both).
