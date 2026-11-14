"""Periodic factual visits to every team, entirely on the viewer side."""
from run_state import read, write


def narration(row):
    text = [f"Around the teams. We are visiting {row['team'].capitalize()}."]
    research = row.get('research') or {}
    done = research.get('done_count')
    if isinstance(done, (int,float)):
        text.append(f'They have completed {int(done)} technologies.')
    if research.get('current') and research.get('label'):
        text.append('Their current research is '+research['label']+'.')
    spm = (row.get('science') or {}).get('spm')
    if isinstance(spm, (int,float)):
        text.append(f'Science production is {spm:.1f} packs per minute.')
    text.append('The camera follows their work as the game continues.')
    return ' '.join(text)


class Tours:
    def __init__(self, op, interval=3600, dwell=45):
        if interval < 120 or dwell < 30:
            raise ValueError('tours require interval >=120 and dwell >=30 seconds')
        self.path = op/'tours.json'
        self.state = read(self.path, {})
        self.interval, self.dwell = interval, dwell

    def choose(self, rows, now):
        """Return (choice, hold): the ordinary director yields during a tour stop."""
        eligible = {r['team']:r for r in rows if not r['stale'] and not r['paused']}
        if now < self.state.get('hold_until',0):
            return None, True
        queue = self.state.get('queue',[])
        if eligible and now >= self.state.get('next',0):
            # Keep a temporarily stale team's place, while a fresh hourly cycle
            # also gives the other teams another visit.
            queue = list(dict.fromkeys(queue+sorted(eligible)))
            self.state.update(queue=queue,next=now+self.interval,cycle=int(now))
            write(self.path,self.state)
        available = [t for t in queue if t in eligible]
        if available and now >= self.state.get('retry',0):
            self.state['pending']=available[0]
            return (available[0],'Team tour'), False
        return None, False

    def failed(self, now):
        # One inaccessible team must not starve the remainder of this cycle.
        queue=self.state.get('queue',[])
        pending=self.state.get('pending')
        if pending in queue:
            queue.remove(pending);queue.append(pending)
        self.state['retry']=now+30
        write(self.path,self.state)

    def success(self, row, now):
        team=row['team']
        self.state['queue']=[t for t in self.state['queue'] if t!=team]
        self.state.update(hold_until=now+self.dwell,retry=0)
        result=dict(id=f"tour:{self.state['cycle']}:{team}",team=team,at=now,text=narration(row))
        self.state['last']=result
        write(self.path,self.state)
        return result
