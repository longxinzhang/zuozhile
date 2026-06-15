import { GLASS_SOFT, INK, LINE_SOFT, MUTED, SHADOW_CARD } from '../theme/ZuozhiTheme';

@Component
export struct StatTile {
  label: string = '';
  value: string = '';
  color: string = INK;

  build() {
    Column({ space: 6 }) {
      Text(this.label)
        .fontSize(12)
        .fontColor(MUTED)
      Text(this.value)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.color)
    }
    .height(76)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(GLASS_SOFT)
    .borderRadius(18)
    .border({ width: 1, color: LINE_SOFT })
    .shadow({ radius: 12, color: SHADOW_CARD, offsetY: 5 })
  }
}

@Component
export struct SmallCounter {
  label: string = '';
  value: number = 0;
  color: string = INK;

  build() {
    Row() {
      Text(this.label)
        .fontSize(13)
        .fontColor(MUTED)
      Blank()
      Text(this.value.toString())
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.color)
    }
    .height(42)
    .layoutWeight(1)
    .padding({ left: 10, right: 10 })
    .backgroundColor(GLASS_SOFT)
    .borderRadius(16)
    .border({ width: 1, color: LINE_SOFT })
  }
}

@Component
export struct BaselineTile {
  label: string = '';
  value: string = '';

  build() {
    Column({ space: 5 }) {
      Text(this.label)
        .fontSize(12)
        .fontColor(MUTED)
      Text(this.value)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
    }
    .height(68)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(GLASS_SOFT)
    .borderRadius(18)
    .border({ width: 1, color: LINE_SOFT })
  }
}
