# /// script
# requires-python = "==3.12.*"
# dependencies = ["matplotlib==3.10.0"]
# ///
"""Render recorded production progress; uv run --no-project tools/mt/market_plot.py MARKET [CONTROL] --out FILE.png."""
import argparse
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from market_fixture import ROOT, TARGETS
from market_metrics import rows

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('market');p.add_argument('control',nargs='?')
    p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    runs=[(a.market,'Market','#1b6ca8')]
    if a.control:runs.append((a.control,'Control','#626262'))
    data=[]
    for run,label,color in runs:
        samples=[s for s in rows(ROOT/'runs'/run/'op/market-samples.jsonl') if s.get('baseline') and s.get('started_tick') is not None]
        assert samples,'no activated samples: '+run
        data.append((samples,label,color))
    end=min((s[-1]['tick']-s[-1]['started_tick'])/3600 for s,_,_ in data)
    fig,axs=plt.subplots(2,3,figsize=(12,6.8),sharex=True,sharey=True)
    names={'electronic-circuit':'Electronic circuits','iron-gear-wheel':'Iron gears','automation-science-pack':'Red science packs'}
    for row,team in enumerate(('green','yellow')):
        for col,(item,target) in enumerate(TARGETS.items()):
            ax=axs[row,col]
            for samples,label,color in data:
                base=samples[0]['baseline']['teams'][team]['made'].get(item,0)
                selected=[s for s in samples if (s['tick']-s['started_tick'])/3600<=end]
                x=[0]+[(s['tick']-s['started_tick'])/3600 for s in selected]
                y=[0]+[min(100,100*(s['teams'][team]['made'][item]-base)/target) for s in selected]
                ax.plot(x,y,label=label,color=color,lw=2)
            ax.axvline(10,color='#bbbbbb',ls=':',lw=1)
            ax.grid(axis='y',alpha=.2);ax.set_ylim(0,105);ax.set_xlim(0,max(end,1))
            if row==0:ax.set_title(f'{names[item]} (target {target:,})',fontsize=11)
            if col==0:ax.set_ylabel(f'{team.title()} — target completed (%)')
            if row==1:ax.set_xlabel('Game minutes after activation')
            ax.spines[['top','right']].set_visible(False)
    title='Prepared-base market / control' if a.control else 'Prepared-base market arm — interim'
    fig.suptitle(title,fontsize=16,y=.98)
    handles,labels=axs[0,0].get_legend_handles_labels();fig.legend(handles,labels,loc='upper center',ncol=2,bbox_to_anchor=(.5,.945),frameon=False)
    note='Same save and model assignments; one paired trial, no uncertainty estimate.' if a.control else 'Single market arm so far; control pending.'
    fig.text(.5,.025,'Production after activation; supplied inventory excluded. Dotted line: expected poor-ore depletion.\n'+note,ha='center',fontsize=9)
    fig.tight_layout(rect=(0,.08,1,.89));a.out.parent.mkdir(parents=True,exist_ok=True)
    fig.savefig(a.out,dpi=150);plt.close(fig);print(a.out)

if __name__=='__main__':main()
