# AutoLoom tasks

- Stored with SwiftData on this iPhone (`TaskItem`: title, notes, created, due date and whether it has a time, completed and when, priority, source, linked memory, linked note, notification id).
- By voice: "görev oluştur: …", "yarına görev oluştur", "bunun için yarına görev oluştur" (after a note: the task links to it), "todo'ya ekle", "bunu yapmam lazım"; questions about the day ("bugün ne yapmam lazım") stay the day plan.
- A task with a time schedules a local notification.
- A task made while a dealer vehicle is active is linked to it.
- The same task within 60 seconds is stored once.
- "Son yaptığını geri al" removes the task just made.
- Tasks tab: today, upcoming, done; Tomorrow / Reschedule; complete by voice ("… görevini tamamla").
- App Intent: "New AutoLoom task" (title, optional due date) without opening the app.
- Tasks are the app's own; Apple Reminders stay separate (the day plan reads both).
